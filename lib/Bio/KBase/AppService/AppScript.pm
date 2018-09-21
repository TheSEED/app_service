

package Bio::KBase::AppService::AppScript;

use FileHandle;
use strict;
use JSON::XS;
use File::Slurp;
use File::Basename;
use IO::File;
use IO::Pipe;
use IO::Select;
use Capture::Tiny 'capture';
use Bio::P3::Workspace::WorkspaceClientExt;
use P3AuthToken;
use Time::HiRes 'gettimeofday';
use LWP::UserAgent;
use REST::Client;
use Bio::KBase::AppService::AppConfig ':all';

use Getopt::Long::Descriptive;
use base 'Class::Accessor';

use Data::Dumper;

__PACKAGE__->mk_accessors(qw(execute_callback preflight_callback donot_create_job_result donot_create_result_folder
			     workspace_url workspace params result_folder
			     app_def params proc_params stdout_file stderr_file
			     hostname json
			     task_id app_service_url));

sub new
{
    my($class, $execute_callback, $preflight_callback) = @_;

    my $self = {
	execute_callback => $execute_callback,
	preflight_callback => $preflight_callback,
    };
    return bless $self, $class;
}

#
# Run the script.
#
# We wish the script to always succeed (from the point of view of the execution environment)
# so we will run the script itself as a forked child, and monitor its execution. We create
# pipes from stdout and stderr and push their output to the app service URL provided as the first argument to
# the script.
#
sub run
{
    my($self, $args) = @_;

    $self->set_task_id();

    my $opt;
    do {
	local @ARGV = @$args;
	($opt, my $usage) = describe_options("%c %o app-service-url app-definition.json param-values.json [stdout-file stderr-file]",
					     ["preflight", "Run the app in preflight mode. Print a JSON object representing the expected runtime, requested CPU count, and memory use for this application invocation."],
					     ["help|h", "Show this help message."]);
	print($usage->text), exit(0) if $opt->help;
	die($usage->text) unless @ARGV == 3 or @ARGV == 5;
	
	my $appserv_url = shift @ARGV;
	$self->app_service_url($appserv_url);
	$args = [@ARGV];
    };

    $self->process_parameters($args);

    if ($opt->preflight)
    {
	return $self->run_preflight();
    }

    #
    # If we are running at the terminal, do not set up this infrastructure.
    #

    if (-t STDIN)
    {
	$self->subproc_run($args);
	exit(0);
    }

    my $ua = LWP::UserAgent->new();
    my $rest = REST::Client->new();
    $rest->setHost($self->app_service_url . "/" . $self->task_id);
    $self->{rest} = $rest;

    my $sel = IO::Select->new();

    my $stdout_pipe = IO::Pipe->new();
    my $stderr_pipe = IO::Pipe->new();

    my $pid = fork();

    if ($pid == 0)
    {
	$stdout_pipe->writer();
	$stderr_pipe->writer();

	open(STDOUT, ">&", $stdout_pipe);
	open(STDERR, ">&", $stderr_pipe);

	$self->subproc_run($args);
	exit(0);
    }

    $self->write_block("pid", $pid);
    $self->write_block("hostname", $self->hostname);
    
    $stdout_pipe->reader();
    $stderr_pipe->reader();

    $stdout_pipe->blocking(0);
    $stderr_pipe->blocking(0);

    $sel->add($stdout_pipe);
    $sel->add($stderr_pipe);

    while ($sel->count() > 0)
    {
	my @ready = $sel->can_read();
	for my $r (@ready)
	{
	    my $which = ($r == $stdout_pipe) ? 'stdout' : 'stderr';
	    my $block;
	    my $n = $r->read($block, 1_000_000);
	    if (!defined($n))
	    {
		warn "error reading $which $r: $!";
		$self->write_block("$which/eof");
		$sel->remove($r);
	    }
	    elsif ($n == 0)
	    {
		print STDERR "EOF on $r\n";
		$self->write_block("$which/eof");
		$sel->remove($r);
	    }
	    else
	    {
		$self->write_block("$which/data", $block);
		my $fh = ($which eq 'stdout') ? \*STDOUT : \*STDERR;
		print $fh $block;
	    }
	}
    }

    print STDERR "Select finished, waitpid $pid\n";
    my $x = waitpid($pid, 0);
    my $rc = $?;
    $self->write_block("exitcode","$rc\n");

    # if ($rc != 0)
    # {
    # 	my $id;
    # 	eval {
    # 	    $id = submit_github_issue($rc, $rest, $task_id, $args);
    # 	}
    # }

    return $rc;
}

sub run_preflight
{
    my($self) = @_;

    return unless $self->preflight_callback();

    $self->preflight_callback()->($self, $self->app_def, $self->params, $self->proc_params);
}

sub set_task_id
{
    my($self) = @_;

    #
    # Hack to finding task id.
    #
    my $host = `hostname -f`;
    $host = `hostname` if !$host;
    chomp $host;
    $self->hostname($host);

    my $task_id = 'TBD';
    if ($ENV{AWE_TASK_ID})
    {
	$task_id = $ENV{AWE_TASK_ID};
    }
    elsif ($ENV{SLURM_JOB_ID})
    {
	$task_id = $ENV{SLURM_JOB_ID};
    }
    elsif ($ENV{PWD} =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_\d+_\d+$/i)
    {
	$task_id = $1;
    }
    else
    {
	$task_id = "UNK-$host-$$";
    }
    $self->task_id($task_id);
}

sub write_block
{
    my($self, $path, $data) = @_;
    $self->{rest}->POST($path, $data);
}

sub process_parameters
{
    my($self, $args) = @_;
    
    my $json = JSON::XS->new->pretty(1)->relaxed(1);
    $self->json($json);

    my $app_def_file = shift @$args;
    my $params_file = shift @$args;

    my $stdout_file = shift @$args;
    my $stderr_file = shift @$args;

    my $app_def = $json->decode(scalar read_file($app_def_file));

    my $params_txt;
    my $params_from_cmdline;
    my $file_error;
    if (open(my $fh, "<", $params_file))
    {
	$params_txt = read_file($fh);
    }
    else
    {
	$file_error = $!;
	# for immediate-mode testing, allow specification of params as inline text.
	$params_from_cmdline = 1;
	$params_txt = $params_file;
    }

    my $params = eval { $json->decode($params_txt); };
    if (!$params)
    {
	die "Error reading or parsing params (file error $!; parse error $@)";
    }
    if (ref($params) ne 'HASH')
    {
	die "Invalid parameters (must be JSON object)";
    }
    #
    # Preprocess parameters to create hash of named parameters, looking for
    # missing required values and filling in defaults.
    #

    my %proc_param;

    my @errors;
    for my $param (@{$app_def->{parameters}})
    {
	my $id = $param->{id};
	if (exists($params->{$id}))
	{
	    my $value = $params->{$param->{id}};
	    #
	    # Maybe validate.
	    #

	    $proc_param{$id} = $value;
	}
	else
	{
	    if ($param->{required})
	    {
		push(@errors, "Required parameter $param->{label} ($id) missing");
		next;
	    }
	    if ($param->{default})
	    {
		$proc_param{$id} = $param->{default};
	    }
	}
    }
    if (@errors)
    {
	die "Errors found in parameter processing:\n    " . join("\n    ", @errors), "\n";
    }

    $self->app_def($app_def);
    $self->params($params);
    $self->proc_params(\%proc_param);
    $self->stdout_file($stdout_file);
    $self->stderr_file($stderr_file);
	 
}

sub subproc_run
{
    my($self, $args) = @_;
    
    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new($self->workspace_url);
    $self->{workspace} = $ws;
	
    if (!defined($self->donot_create_result_folder()) || $self->donot_create_result_folder() == 0) {
    	$self->create_result_folder();
    }
    my $start_time = gettimeofday;

    my $job_output;
    if ($self->stdout_file)
    {
	my $stdout_fh = IO::File->new($self->stdout_file, "w+");
	my $stderr_fh = IO::File->new($self->stderr_file, "w+");
	
	capture(sub { $job_output = $self->execute_callback->($self, $self->app_def, $self->params, $self->proc_params) } , stdout => $stdout_fh, stderr => $stderr_fh);
    }
    else
    {
	$job_output = $self->execute_callback->($self, $self->app_def, $self->params, $self->proc_params);
    }

    if ($self->params->{output_path} && $self->params->{output_path} && !$self->donot_create_result_folder())
    {
	my $end_time = gettimeofday;
	my $elap = $end_time - $start_time;
	
	my $files = $ws->ls({ paths => [ $self->result_folder ], recursive => 1});
	
	my $task_id = $self->task_id;
	
	my $job_obj = {
	    id => $task_id,
	    app => $self->app_def,
	    parameters => $self->proc_params,
	    start_time => $start_time,
	    end_time => $end_time,
	    elapsed_time => $elap,
	    hostname => $self->hostname,
	    output_files => [ map { [ $_->[2] . $_->[0], $_->[4] ] } @{$files->{$self->result_folder}}],
	    job_output => $job_output,
	};
	
	my $file = $self->params->{output_path} . "/" . $self->params->{output_file};
	$ws->save_data_to_file($self->json->encode($job_obj), {}, $file, 'job_result',1);
    }
    delete $self->{workspace};
}


sub create_result_folder
{
    my($self) = @_;

    my $params = $self->params;

    if ($params->{output_path} && $params->{output_file})
    {
	my $base_folder = $params->{output_path};
	my $result_folder = $base_folder . "/." . $params->{output_file};
	$self->result_folder($result_folder);
	$self->workspace->create({overwrite => 1, objects => [[$result_folder, 'folder', { application_type => $self->app_def->{id}}]]});
    }
}

sub token
{
    my($self) = @_;
    my $token = P3AuthToken->new(ignore_authrc => ($ENV{KB_INTERACTIVE} ? 0 : 1));
    return $token;
}

sub stage_in
{
    my($self, $files, $dest_path, $replace_spaces) = @_;

    $files = [$files] if !ref($files);

    my @pairs;
    my $ret = {};
    for my $f (@$files)
    {
	my $base = basename($f);
	if ($replace_spaces)
	{
	    $base =~ s/\s/_/g;
	}
	my $out = "$dest_path/$base";
	my $fh = FileHandle->new($out, "w");
	$fh or die "Cannot write $out: $!";
	push(@pairs, [$f,  $fh]);
	$ret->{$f} = $out;
    }

    print STDERR Dumper($files, \@pairs);
    $self->workspace()->copy_files_to_handles(1, $self->token(), \@pairs);
    return $ret;
}

1;
