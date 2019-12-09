

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
use Getopt::Long::Descriptive;
use Time::HiRes 'gettimeofday';
use LWP::UserAgent;
use REST::Client;
use Bio::KBase::AppService::AppConfig ':all';

use base 'Class::Accessor';

use Data::Dumper;

__PACKAGE__->mk_accessors(qw(execute_callback preflight_callback donot_create_job_result donot_create_result_folder
			     workspace_url workspace params raw_params app_definition result_folder
			     json
			     task_id app_service_url));

=head1 NAME

Bio::KBase::AppService::AppScript - backend processing for App wrappers

=head1 SYNOPSIS

    $app = Bio::KBase::AppService::AppScript->new(\&run_callback, \&preflight_callback);
    $app->run(\@ARGV)

=head1 DESCRIPTION

C<AppScript> wraps the logic for starting and monitoring application scripts.

Theory of operation:

=over 4

=item 1. 

Application script (scripts/App-Something.pl) is started by the P3 runtime system. 
It is provided command line arguments defining the location of the output
collection service, the application definition file, and the parameters
provided for this application run.

If this is a preflight run, the C<--preflight> option is provided.

=item 2. 

AppScript instance is created and provided callbacks for execution and
preflight. Preflight callback is optional but recommended.

=item 3. 

AppScript validates the parameters against the app description.

=item 4. 

If this is a preflight run and there is a preflight callback, 
the preflight callback is executed and the application terminates.

It is expected the preflight callback writes a JSON document containing
preflight data to the standard output.

=item 5a. 

If the program is running under the control of the P3 shepherd (detectable by
the existence of the environment variable P3_SHEPHERD_PID), the execute
callback is invoked and no further processing is performed.

=item 5b

If the program is not running under the control of the P3 shepherd,
and it is running in an interactive terminal session, the
run callback is invoked (as below) and no further processing is performed.

=item 5c.

Otherwise, we set up an execution environment for the execute callback. We create pipes to map standard 
output and standard error, and fork the process to create a child in which to execute
the callback. The process ID of the created process and the hostname we are executing
on are written to the output collection service, and the main process begins waiting for
output from the child.

As output comes in, it is sent to the output collection service as well as being
written to the current standard output or error stream.

When the child process completes, its return code is written to the output 
collection service.
  
=back

=head1 PREFLIGHT

At the time that the request for creation of application instance (a task) is made, 
a preflight request will be executed on the task scheduler host and given the
application specification and parameters as requested by the user.

If the application provides a preflight callback, it will be invoked and
passed that information. The preflight callback will emit a preflight JSON
document on the standard output stream

The preflight document is an object with the following keys defined:

=over 4

=item B<cpu>

Number of CPUs requested for execution. The runtime system may execute the 
job on fewer CPUs if that will enable more rapid scheduling.

=item B<memory>

Amount of RAM required for execution, including buffer cache. The scheduler
attempts to guarantee that amount of RAM be available, and may also
provide a hard limit at that amount to the RAM available to be allocated.

=item B<runtime>

Estimated runtime in seconds. The script may be terminated if this time
limit is exceeded.

=item B<policy_data>

Optional scheduling policy data. If provided, the value is itself an object
with a key of name of the policy and value being the arbitrary data 
to be interpreted by the named policy plugin, if active in the scheduling system.

=back

If a preflight document is not returned, the applicaiton specification defines
C<default_memory>, C<default_cpu>, and C<default_runtime> values.

=head1 SCHEDULING POLICY

The scheduler may have policy plugins activated. These plugins allow for 
site-specfic activity to be added to the scheduler. The initial example is a 
Bebop assembly scheduler policy that attempts to pluck one or more assembly jobs
from the queue to schedule to a single Bebop node if one is available and if the
jobs meet certain criteria. We embed the knowledge of the criteria in the preflight
logic in the assembly application, and use the policy field of the preflight
data to pass that to the policy plugin.

=head1 METHODS

=over 4

=item B<new>

=over 4

=item Arguments: L<\&execute_callback>, L<\&preflight_callback>

=item Return value: Ignored.

=back

Create an instance. 

=cut

sub new
{
    my($class, $execute_callback, $preflight_callback) = @_;

    my $self = {
	execute_callback => $execute_callback,
	preflight_callback => $preflight_callback,
	start_time => scalar gettimeofday,
	json => JSON::XS->new->pretty(1),
    };

    bless $self, $class;

    $self->set_task_id();

    return $self;
}

sub host
{
    my($self) = @_;
    my $host;
    if (!defined($host = $self->{host}))
    {
	$host = `hostname -f`;
	$host = `hostname` if !$host;
	chomp $host;
	$self->{host} = $host;
    }
    return $host;
}

sub run_preflight
{
    my($self) = @_;
    
    return unless $self->preflight_callback();
    
    return $self->preflight_callback()->($self, $self->app_definition, $self->raw_params, $self->params);
}

=item B<run>

=over 4

=item Arguments: L<\@args>

Run the script, in either preflight or execution mode.  L<\@args> is a list reference containing the 
command line parameters.

=back

=cut

sub run
{
    my($self, $args) = @_;

    my($opt, $app_def_file, $params_file, $appserv_url);
    do {
	local @ARGV = @$args;
	($opt, my $usage) = describe_options("%c %o app-service-url app-definition.json param-values.json",
					     ["user-error-file=s", "File to which user-readable errors are written"],
					     ["preflight=s", "Run the app in preflight mode. Write a JSON object to the file specified representing the expected runtime, requested CPU count, and memory use for this application invocation."],
					     
					     ["help|h", "Show this help message."]);
	print($usage->text), exit(0) if $opt->help;

	#
	# Legacy support. If we're invoked with three arguments and we are running under the
	# shepherd, ignore the first argument. Allow just two arguments when under the shepherd.
	#
	if (exists($ENV{P3_SHEPHERD_PID}))
	{
	    if (@ARGV == 3)
	    {
		shift @ARGV;
	    }

	    die($usage->text) if @ARGV != 2;

	    ($app_def_file, $params_file) = @ARGV;
	}
	else
	{
	    die($usage->text) if @ARGV != 3;
	    ($appserv_url, $app_def_file, $params_file) = @ARGV;
	    $self->app_service_url($appserv_url);
	}
    };
    
    my $error_fh;
    open($error_fh, ">>", $opt->user_error_file);
    $self->{error_fh} = $error_fh;
    $error_fh->autoflush(1);

    $self->preprocess_parameters($app_def_file, $params_file);

    $self->{workspace} = Bio::P3::Workspace::WorkspaceClientExt->new($self->workspace_url);
    
    if ($opt->preflight)
    {
	open(my $fh, ">", $opt->preflight) or die "Cannot write preflight to " . $opt->preflight . ": $!";

	my $data;

	eval {
	    $data = $self->run_preflight();
	};
	if ($@)
	{
	    print $error_fh "Error running preflight checks: $@";
	    die $@;
	}
	    
	if (ref($data) eq 'HASH')
	{
	    print $fh $self->json->encode($data);
	}
	close($fh) or die "Cannot close preflight fh for file " . $opt->preflight . ": $!";
	return;
    }
    
    #
    # If we are running at the terminal or are running under the shepherd, 
    # do not set up the logging infrastructure.
    #

    if (exists($ENV{P3_SHEPHERD_PID}))
    {
	print STDERR "Executing under P3 shepherd $ENV{P3_SHEPHERD_PID}\n";
	exit $self->subproc_run();
    }
    elsif (-t STDIN)
    {
	print STDERR "Executing in interactive terminal\n";
	exit $self->subproc_run();
    }
    else
    {
	$self->run_with_monitoring();
    }
}

sub run_with_monitoring
{
    my($self) = @_;

    my $appserv_url = $self->app_service_url();

    my $ua = LWP::UserAgent->new();
    my $rest = REST::Client->new();
    $rest->setHost("$appserv_url/" . $self->task_id);
    print STDERR "Logging to " . "$appserv_url/" . $self->task_id . "\n";
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

	exit $self->subproc_run();
    }

    $self->write_block("pid", $pid);
    $self->write_block("hostname", $self->host);
    
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
		if ($! ne '')
		{
		    warn "error reading $which: $!";
		}
		else
		{
		    print STDERR "EOF on $which\n";
		}
		$self->write_block("$which/eof");
		$sel->remove($r);
	    }
	    elsif ($n == 0)
	    {
		print STDERR "EOF on $which\n";
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
    # 	    $id = submit_github_issue($rc, $rest, $self->task_id, $args);
    # 	}
    # }

    return $rc;
}

sub write_block
{
    my($self, $path, $data) = @_;
    my $res = $self->{rest}->POST($path, $data);
    #print Dumper($res);
}

sub subproc_run
{
    my($self) = @_;
    
    $self->initialize_workspace();
    $self->setup_folders();

    my $job_output;
    my $success = 1;
    my $failure_report;

    eval {
	$job_output = $self->execute_callback->($self, $self->app_definition, $self->raw_params, $self->params);
    };
    
    if ($@)
    {
	print STDERR "Exception raised while executing: $@";
	$failure_report = <<END;
Your job has failed with an exception:

$@
END
	$success = 0;
    }

    $self->write_results($job_output, $success, $failure_report);
    delete $self->{workspace};
    # return here turns into the process exitcode
    return ($success ? 0 : 1);
}

sub set_task_id
{
    my($self) = @_;

    #
    # Hack to finding task id.
    #

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
	my $host = $self->host;
	$task_id = "UNK-$host-$$";
	$task_id =~ s/\./_/g;
    }
    $self->task_id($task_id);
    print STDERR "Running process $$ as task $task_id\n";
}

sub create_result_folder
{
    my($self) = @_;

    my $base_folder = $self->params->{output_path};
    my $result_folder = $base_folder . "/." . $self->params->{output_file};
    $self->result_folder($result_folder);
    $self->workspace->create({overwrite => 1, objects => [[$result_folder, 'folder', { application_type => $self->app_definition->{id}}]]});

    #
    # Remove any job failed reports that were left from a prior run.
    #
    eval { $self->workspace->delete({ objects => ["$result_folder/JobFailed.txt"] }) };
    # if ($@) { warn "delete $result_folder/JobFailed.txt failed: $@"; }
    eval { $self->workspace->delete({ objects => ["$result_folder/JobFailed.html"] }) };
    # if ($@) { warn "delete $result_folder/JobFailed.html failed: $@"; }
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

sub preprocess_parameters
{
    my($self, $app_def_file, $params_file) = @_;
    
    my $json = JSON::XS->new->pretty(1)->relaxed(1);

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

	    if ($param->{type} eq 'bool')
	    {
		if ($value eq 'false')
		{
		    print STDERR "Fixing false value to 0 for $id\n";
		    $value = 0;
		}
		elsif ($value eq 'true')
		{
		    print STDERR "Fixing true value to 1 for $id\n";
		    $value = 1;
		}
	    }
		    
	    
	    #
	    # Maybe validate.
	    #

	    if (!defined($value))
	    {
		#
		# There is a difference between no value given, and a value
		# of undefined. For now if we have a default value,
		# replace the undefined with the default.
		#
		$value = $param->{default} if defined($param->{default});
	    }
	    $proc_param{$id} = $value;
	}
	else
	{
	    if ($param->{required})
	    {
		push(@errors, "Required parameter $param->{label} ($id) missing");
		next;
	    }
	    if (defined($param->{default}))
	    {
		$proc_param{$id} = $param->{default};
	    }
	}
    }
    if (@errors)
    {
	die "Errors found in parameter processing:\n    " . join("\n    ", @errors), "\n";
    }

    $self->{raw_params} = $params;
    $self->{params} = \%proc_param;
    $self->{app_definition} = $app_def;
    return \%proc_param;
}

sub initialize_workspace
{
    my($self) = @_;
	 
    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new($self->workspace_url);
    $self->{workspace} = $ws;
}

sub setup_folders
{
    my($self) = @_;
    if (!defined($self->donot_create_result_folder()) || $self->donot_create_result_folder() == 0) {
    	$self->create_result_folder();
    }
}

sub write_results
{
    my($self, $job_output, $success, $failure_report) = @_;
    
    return if $self->donot_create_result_folder();

    my $start_time = $self->{start_time};
    my $end_time = gettimeofday;
    my $elap = $end_time - $start_time;
    
    my $files = $self->workspace->ls({ paths => [ $self->result_folder ], recursive => 1});

    $job_output //= "";
    
    my $job_obj = {
	id => $self->task_id,
	app => $self->app_definition,
	parameters => $self->params,
	start_time => $start_time,
	end_time => $end_time,
	elapsed_time => $elap,
	hostname => $self->host,
	output_files => [ map { [ $_->[2] . $_->[0], $_->[4] ] } @{$files->{$self->result_folder}}],
	job_output => $job_output,
	success => ($success ? 1 : 0),
    };

    my $file = $self->params->{output_path} . "/" . $self->params->{output_file};
    $self->workspace->save_data_to_file($self->json->encode($job_obj), {}, $file, 'job_result',1);
    if ($failure_report)
    {
	my $type = ($failure_report =~ /<\S+>/) ? 'html' : 'txt';
	$self->workspace->save_data_to_file($failure_report, {},
					    $self->params->{output_path}. "/." . $self->params->{output_file} . "/JobFailed.$type", $type, 1);
    }
	
}


1;
