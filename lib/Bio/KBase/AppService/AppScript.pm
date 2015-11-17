

package Bio::KBase::AppService::AppScript;

use strict;
use JSON::XS;
use File::Slurp;
use IO::File;
use IO::Pipe;
use IO::Select;
use Capture::Tiny 'capture';
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AuthToken;
use Time::HiRes 'gettimeofday';
use LWP::UserAgent;
use REST::Client;
use Bio::KBase::AppService::AppConfig ':all';

use base 'Class::Accessor';

use Data::Dumper;

__PACKAGE__->mk_accessors(qw(callback donot_create_job_result donot_create_result_folder workspace_url workspace params app_definition result_folder));

sub new
{
    my($class, $callback) = @_;

    my $self = {
	callback => $callback,
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

    #
    # Hack to finding task id.
    #
    my $task_id = 'TBD';
    if ($ENV{PWD} =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_\d+_\d+$/i)
    {
	$task_id = $1;
    }
    else
    {
	$task_id = "UNK-$$";
    }

    @$args == 3 or @$args == 5 or die "Usage: $0 app-service-url app-definition.json param-values.json [stdout-file stderr-file]\n";
    
    my $appserv_url = shift @$args;

    my $ua = LWP::UserAgent->new();
    my $rest = REST::Client->new();
    $rest->setHost("$appserv_url/$task_id");
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

    my $host = `hostname -f`;
    $host = `hostname` if !$host;
    chomp $host;

    $self->write_block("pid", $pid);
    $self->write_block("hostname", $host);
    
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

    return $rc >> 8;
}

sub write_block
{
    my($self, $path, $data) = @_;
    $self->{rest}->POST($path, $data);
}

sub subproc_run
{
    my($self, $args) = @_;
    
    my $json = JSON::XS->new->pretty(1);

    my $app_def_file = shift @$args;
    my $params_file = shift @$args;

    my $stdout_file = shift @$args;
    my $stderr_file = shift @$args;

    my $app_def = $json->decode(scalar read_file($app_def_file));
    my $params =  $json->decode(scalar read_file($params_file));

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
	 
    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new($self->workspace_url);
    $self->{workspace} = $ws;
    $self->{params} = \%proc_param;
    $self->{app_definition} = $app_def; 
	
    if (!defined($self->donot_create_result_folder()) || $self->donot_create_result_folder() == 0) {
    	$self->create_result_folder();
    }

    my $host = `hostname -f`;
    $host = `hostname` if !$host;
    chomp $host;
    my $start_time = gettimeofday;

    my $job_output;
    if ($stdout_file)
    {
	my $stdout_fh = IO::File->new($stdout_file, "w+");
	my $stderr_fh = IO::File->new($stderr_file, "w+");
	
	capture(sub { $job_output = $self->callback->($self, $app_def, $params, \%proc_param) } , stdout => $stdout_fh, stderr => $stderr_fh);
    }
    else
    {
	$job_output = $self->callback->($self, $app_def, $params, \%proc_param);
    }

    my $end_time = gettimeofday;
    my $elap = $end_time - $start_time;

    my $files = $ws->ls({ paths => [ $self->result_folder ], recursive => 1});

    #
    # Hack to finding task id.
    #
    my $task_id = 'TBD';
    if ($ENV{PWD} =~ /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})_\d+_\d+$/i)
    {
	$task_id = $1;
    }
    else
    {
	$task_id = "Not found in '$ENV{PWD}'";
    }

    my $job_obj = {
	id => $task_id,
	app => $app_def,
	parameters => \%proc_param,
	start_time => $start_time,
	end_time => $end_time,
	elapsed_time => $elap,
	hostname => $host,
	output_files => [ map { [ $_->[2] . $_->[0], $_->[4] ] } @{$files->{$self->result_folder}}],
	job_output => $job_output,
    };

    my $file = $self->params->{output_path} . "/" . $self->params->{output_file};
    if (!defined($self->donot_create_job_result()) || $self->donot_create_job_result() == 0) {
	$ws->save_data_to_file($json->encode($job_obj), {}, $file, 'job_result',1);
    }
    delete $self->{workspace};
}


sub create_result_folder
{
    my($self) = @_;

    my $base_folder = $self->params->{output_path};
    my $result_folder = $base_folder . "/." . $self->params->{output_file};
    $self->result_folder($result_folder);

    $self->workspace->create({overwrite => 1, objects => [[$result_folder, 'folder', { application_type => $self->app_definition->{id}}]]});
}

sub token
{
    my($self) = @_;
    my $token = Bio::KBase::AuthToken->new(ignore_authrc => ($ENV{KB_INTERACTIVE} ? 0 : 1));
    return $token;
}

1;
