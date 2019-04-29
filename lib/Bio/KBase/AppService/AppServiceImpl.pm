package Bio::KBase::AppService::AppServiceImpl;
use strict;
# Use Semantic Versioning (2.0.0-rc.1)
# http://semver.org 
our $VERSION = "0.1.0";

=head1 NAME

AppService

=head1 DESCRIPTION



=cut

#BEGIN_HEADER

use JSON::XS;
use MongoDB;
use Data::Dumper;
use Bio::KBase::AppService::Awe;
use Bio::KBase::AppService::Shock;
use Bio::KBase::AppService::Util;
use Bio::P3::DeploymentConfig;
use File::Slurp;
use Data::UUID;
use Plack::Request;
use IO::File;
use IO::Handle;

sub _task_info
{
    my($self, $env) = @_;
    my $req = Plack::Request->new($env);
    my $path = $req->path_info;
    print "$path\n";

    #
    # Ugly manual parsing of REST paths. If we do anything more complex this
    # should become a Dancer thing.
    #

    if ($path !~ s,^/+([a-zA-Z0-9_-]+)/,,)
    {
	return $req->new_response(404)->finalize();
    }
    my $task = $1;
    
    my $dir = $self->{task_status_dir};

    if ($req->method eq 'GET')
    {
	#
	# We've pulled the task off the front, and should be left with just a
	# bare filename in the task directory.
	#

	if ($path =~ /^[a-zA-Z0-9_-]+$/)
	{
	    my $file_path = "$dir/$task/$path";
	    if (-f $file_path)
	    {
		my $fh = IO::Handle->new;
		if (open($fh, "-|", "sed", "-e", '/un=/s/sig=[a-z0-9]*/sig=XXX/', $file_path))
		{
		    my $res = $req->new_response(200);
		    $res->body($fh);
		    return $res->finalize;
		}
		else
		{
		    print STDERR "Could not open $dir/$task/$path: $!";
		    return $req->new_response(404)->finalize();
		}
	    }
	    else
	    {
		print STDERR "Could not open $dir/$task/$path: $!";
		return $req->new_response(404)->finalize();
	    }
	}
	else
	{
	    print STDERR "Invalid path '$path'\n";
	    return $req->new_response(404)->finalize();
	}
    }
    elsif ($req->method eq 'POST')
    {
	my($file, $multi, $tpath);

	my @parts = split('/', $path);

	# print STDERR Dumper(\@parts, $dir);
	
	if ($dir)
	{
	    my $tdir = "$dir/$task";
	    -d $tdir || mkdir($tdir) || warn "Error creating $tdir: $!";
	    
	    $file = shift @parts;
	    
	    $multi = shift @parts;
	    
	    if ($file)
	    {
		$tpath = "$tdir/$file";
	    }
	}
	
	# print STDERR Dumper($dir, $task, $file, $multi, $tpath);
	my $out;
	if ($tpath && $multi eq 'data')
	{
	    open($out, ">>", $tpath);
	}
	elsif ($tpath && !$multi)
	{
	    open($out, ">", $tpath);
	}
	elsif ($path && $multi eq 'eof')
	{
	    open($out, ">", "${tpath}.EOF");
	}

	if ($out)
	{
	    my $fh = $req->body;
	    my $buf;
	    while ($fh->read($buf, 4096))
	    {
		print $out $buf;
	    }
	    close($out);
	}
	
	my $res = $req->new_response(200);
	$res->finalize();
    }
    else
    {
	return $req->new_response(404)->finalize();
    }
}
    
sub _lookup_task
{
    my($self, $awe, $task_id) = @_;

    my $task;
    my $q = "/job/$task_id";
    # print STDERR "_lookup_task: $q\n";
    my ($res, $error) = $awe->GET($q);
    if ($res)
    {
	$task = $self->_awe_to_task($res->{data});
    }
    
    return $task;
}

#
# Map an AWE state to our status.
# Mostly the same, but we map suspend to failed.
# From https://github.com/MG-RAST/AWE/blob/master/lib/core/task.go#L14:
#
# const (
#               TASK_STAT_INIT       = "init"
#               TASK_STAT_QUEUED     = "queued"
#               TASK_STAT_INPROGRESS = "in-progress"
#               TASK_STAT_PENDING    = "pending"
#               TASK_STAT_SUSPEND    = "suspend"
#               TASK_STAT_COMPLETED  = "completed"
#               TASK_STAT_SKIPPED    = "user_skipped"
#               TASK_STAT_FAIL_SKIP  = "skipped"
#               TASK_STAT_PASSED     = "passed"
#       )

sub _awe_state_to_status
{
    my($self, $state) = @_;

    my $nstate = $state;
    if ($state eq 'suspend')
    {
	$nstate = 'failed';
    }
    #
    # Normalize dash/_ use.
    #
    $nstate =~ s/_/-/g;
    return $nstate;
}


sub _awe_to_task
{
    my($self, $t) = @_;

    my $id = $t->{id};
    my $i = $t->{info};
    my $u = $i->{userattr};
    my $atask = $t->{tasks}->[0];

    my $astat = $self->_awe_state_to_status($t->{state});

    my $task = {
	id => $id,
	parent_id => $u->{parent_task},
	app => $u->{app_id},
	workspace => $u->{workspace},
	parameters => decode_json($u->{parameters}),
	user_id => $i->{user},
	awe_status => $astat,
	status => $astat,
	submit_time => $i->{submittime},
	start_time => $i->{startedtime},
	completed_time => $i->{completedtime},
	stdout_shock_node => $self->_lookup_output($atask, "stdout.txt"),
	stderr_shock_node => $self->_lookup_output($atask, "stderr.txt"),
	awe_stdout_shock_node => $self->_lookup_output($atask, "awe_stdout.txt"),
	awe_stderr_shock_node => $self->_lookup_output($atask, "awe_stderr.txt"),
	
    };

    #
    # Check exit code if available. Overrides status returned from awe.
    #

    return $task if $astat eq 'deleted';
    
    my $rc = $self->{util}->get_task_exitcode($id);
    if (defined($rc))
    {
	if ($rc == 0 && $astat ne 'completed')
	{
	    warn "Task $id: awe shows $astat but exitcode = 0. Setting to completed\n";
	    $task->{status} = 'completed';
	}
	elsif ($rc != 0 && ($astat eq 'in-progress' || $astat eq 'completed'))
	{
	    warn "Task $id: awe shows $astat but exitcode=$rc. Setting to failed\n";
	    $task->{status} = 'failed';
	}
    }
    return $task;
}

sub _lookup_output
{
    my($self, $atask, $filename) = @_;
    my $outputs = $atask->{outputs};


    my $file;
    #
    # Support new job object.
    # 
    if (ref($outputs) eq 'ARRAY')
    {
       ($file) = grep { $_->{filename} eq $filename } @$outputs;
    }
    else
    {
       $file = $outputs->{$filename};
    }
    # print STDERR Dumper($atask);

    if ($file)
    {
	my $h = $file->{host};
	my $n = $file->{node};
	if ($h && $n && $n ne '-')
	{
	    return "$h/node/$n";
	}
    }
    return "";
}
#END_HEADER

sub new
{
    my($class, @args) = @_;
    my $self = {
    };
    bless $self, $class;
    #BEGIN_CONSTRUCTOR

    my $cfg = Bio::P3::DeploymentConfig->new($ENV{KB_SERVICE_NAME} || "AppService");
    my $awe_server = $cfg->setting("awe-server");
    $self->{awe_server} = $awe_server;
    my $shock_server = $cfg->setting("shock-server");
    $self->{shock_server} = $shock_server;
    my $app_dir = $cfg->setting("app-directory");
    $self->{app_dir} = $app_dir;

    $self->{awe_mongo_db} = $cfg->setting("awe-mongo-db") || "AWEDB";
    $self->{awe_mongo_host} = $cfg->setting("awe-mongo-host") || "localhost";
    $self->{awe_mongo_port} = $cfg->setting("awe-mongo-port") || 27017;
    $self->{awe_mongo_user} = $cfg->setting("awe-mongo-user");
    $self->{awe_mongo_pass} = $cfg->setting("awe-mongo-pass");
    $self->{awe_clientgroup} = $cfg->setting("awe-clientgroup") || "";

    $self->{task_status_dir} = $cfg->setting("task-status-dir");
    $self->{service_url} = $cfg->setting("service-url");

    $self->{util} = Bio::KBase::AppService::Util->new($self);

    $self->{status_file} = $cfg->setting("status-file");
	
    #END_CONSTRUCTOR

    if ($self->can('_init_instance'))
    {
	$self->_init_instance();
    }
    return $self;
}
=head1 METHODS
=head2 service_status

  $return = $obj->service_status()

=over 4


=item Parameter and return types

=begin html

<pre>
$return is a reference to a list containing 2 items:
	0: (submission_enabled) an int
	1: (status_message) a string
</pre>

=end html

=begin text

$return is a reference to a list containing 2 items:
	0: (submission_enabled) an int
	1: (status_message) a string

=end text



=item Description


=back

=cut

sub service_status
{
    my $self = shift;

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($return);
    #BEGIN service_status

    my($stat, $txt) = $self->{util}->service_status($ctx);
    $return = [$stat, $txt];

    #END service_status
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to service_status:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($return);
}


=head2 enumerate_apps

  $return = $obj->enumerate_apps()

=over 4


=item Parameter and return types

=begin html

<pre>
$return is a reference to a list where each element is an App
App is a reference to a hash where the following keys are defined:
	id has a value which is an app_id
	script has a value which is a string
	label has a value which is a string
	description has a value which is a string
	parameters has a value which is a reference to a list where each element is an AppParameter
app_id is a string
AppParameter is a reference to a hash where the following keys are defined:
	id has a value which is a string
	label has a value which is a string
	required has a value which is an int
	default has a value which is a string
	desc has a value which is a string
	type has a value which is a string
	enum has a value which is a string
	wstype has a value which is a string
</pre>

=end html

=begin text

$return is a reference to a list where each element is an App
App is a reference to a hash where the following keys are defined:
	id has a value which is an app_id
	script has a value which is a string
	label has a value which is a string
	description has a value which is a string
	parameters has a value which is a reference to a list where each element is an AppParameter
app_id is a string
AppParameter is a reference to a hash where the following keys are defined:
	id has a value which is a string
	label has a value which is a string
	required has a value which is an int
	default has a value which is a string
	desc has a value which is a string
	type has a value which is a string
	enum has a value which is a string
	wstype has a value which is a string

=end text



=item Description


=back

=cut

sub enumerate_apps
{
    my $self = shift;

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($return);
    #BEGIN enumerate_apps
    $return = [];

    push(@$return, $self->{util}->enumerate_apps());

    return sub {
	my($cb) = @_;
	print "Got cb=$cb\n";
	$cb->($return);
    };
    
    #END enumerate_apps
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_apps:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($return);
}


=head2 start_app

  $task = $obj->start_app($app_id, $params, $workspace)

=over 4


=item Parameter and return types

=begin html

<pre>
$app_id is an app_id
$params is a task_parameters
$workspace is a workspace_id
$task is a Task
app_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
workspace_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
task_status is a string
</pre>

=end html

=begin text

$app_id is an app_id
$params is a task_parameters
$workspace is a workspace_id
$task is a Task
app_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
workspace_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
task_status is a string

=end text



=item Description


=back

=cut

sub start_app
{
    my $self = shift;
    my($app_id, $params, $workspace) = @_;

    my @_bad_arguments;
    (!ref($app_id)) or push(@_bad_arguments, "Invalid type for argument \"app_id\" (value was \"$app_id\")");
    (ref($params) eq 'HASH') or push(@_bad_arguments, "Invalid type for argument \"params\" (value was \"$params\")");
    (!ref($workspace)) or push(@_bad_arguments, "Invalid type for argument \"workspace\" (value was \"$workspace\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to start_app:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($task);
    #BEGIN start_app

    print STDERR "start_app\n";
    my $cb = $self->{util}->start_app_with_preflight($ctx, $app_id, $params, { workspace => $workspace });
    return $cb;
    
    #END start_app
    my @_bad_returns;
    (ref($task) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"task\" (value was \"$task\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to start_app:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($task);
}


=head2 start_app2

  $task = $obj->start_app2($app_id, $params, $start_params)

=over 4


=item Parameter and return types

=begin html

<pre>
$app_id is an app_id
$params is a task_parameters
$start_params is a StartParams
$task is a Task
app_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
StartParams is a reference to a hash where the following keys are defined:
	parent_id has a value which is a task_id
	workspace has a value which is a workspace_id
task_id is a string
workspace_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_status is a string
</pre>

=end html

=begin text

$app_id is an app_id
$params is a task_parameters
$start_params is a StartParams
$task is a Task
app_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
StartParams is a reference to a hash where the following keys are defined:
	parent_id has a value which is a task_id
	workspace has a value which is a workspace_id
task_id is a string
workspace_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_status is a string

=end text



=item Description


=back

=cut

sub start_app2
{
    my $self = shift;
    my($app_id, $params, $start_params) = @_;

    my @_bad_arguments;
    (!ref($app_id)) or push(@_bad_arguments, "Invalid type for argument \"app_id\" (value was \"$app_id\")");
    (ref($params) eq 'HASH') or push(@_bad_arguments, "Invalid type for argument \"params\" (value was \"$params\")");
    (ref($start_params) eq 'HASH') or push(@_bad_arguments, "Invalid type for argument \"start_params\" (value was \"$start_params\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to start_app2:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($task);
    #BEGIN start_app2
    print STDERR "start_app2\n";
    # $task = $self->{util}->start_app($ctx, $app_id, $params, $start_params);
    my $cb = $self->{util}->start_app_with_preflight($ctx, $app_id, $params, $start_params);
    return $cb;

    #END start_app2
    my @_bad_returns;
    (ref($task) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"task\" (value was \"$task\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to start_app2:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($task);
}


=head2 query_tasks

  $tasks = $obj->query_tasks($task_ids)

=over 4


=item Parameter and return types

=begin html

<pre>
$task_ids is a reference to a list where each element is a task_id
$tasks is a reference to a hash where the key is a task_id and the value is a Task
task_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string
</pre>

=end html

=begin text

$task_ids is a reference to a list where each element is a task_id
$tasks is a reference to a hash where the key is a task_id and the value is a Task
task_id is a string
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string

=end text



=item Description


=back

=cut

sub query_tasks
{
    my $self = shift;
    my($task_ids) = @_;

    my @_bad_arguments;
    (ref($task_ids) eq 'ARRAY') or push(@_bad_arguments, "Invalid type for argument \"task_ids\" (value was \"$task_ids\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to query_tasks:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($tasks);
    #BEGIN query_tasks

    my $awe = Bio::KBase::AppService::Awe->new($self->{awe_server}, $ctx->token);

    $tasks = {};

    for my $task_id (@$task_ids)
    {
	my ($res, $error) = $awe->job($task_id);
	if ($res)
	{
	    my $task = $self->_awe_to_task($res);
	    $tasks->{$task_id} = $task;
	}
    }

    #END query_tasks
    my @_bad_returns;
    (ref($tasks) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"tasks\" (value was \"$tasks\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_tasks:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($tasks);
}


=head2 query_task_summary

  $status = $obj->query_task_summary()

=over 4


=item Parameter and return types

=begin html

<pre>
$status is a reference to a hash where the key is a task_status and the value is an int
task_status is a string
</pre>

=end html

=begin text

$status is a reference to a hash where the key is a task_status and the value is an int
task_status is a string

=end text



=item Description


=back

=cut

sub query_task_summary
{
    my $self = shift;

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($status);
    #BEGIN query_task_summary

    #
    # Summarize counts of tasks of each type for this user.
    #
    # Query mongo for the types available, then count.
    #

    my $mongo = MongoDB::MongoClient->new(host => $self->{awe_mongo_host},
					  port => $self->{awe_mongo_port},
					  db_name => $self->{awe_mongo_db},
					  (defined($self->{awe_mongo_user}) ? (username => $self->{awe_mongo_user}) : ()),
					  (defined($self->{awe_mongo_pass}) ? (password => $self->{awe_mongo_pass}) : ()),
					 );
    my $db = $mongo->get_database($self->{awe_mongo_db});
    my $col = $db->get_collection("Jobs");

    my $states = $db->run_command( [ distinct => "Jobs", key => "state", query => { 'info.user' => $ctx->user_id } ] );

    $status = {};

    for my $state (@{$states->{values}})
    {
	next if $state eq 'deleted';

	my $n = $col->find({"info.user" =>  $ctx->user_id, state => $state, "info.pipeline" => "AppService"})->count();
	$status->{$self->_awe_state_to_status($state)} = $n;
    }

    undef $col;
    undef $db;
    undef $mongo;
    
    #END query_task_summary
    my @_bad_returns;
    (ref($status) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"status\" (value was \"$status\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_task_summary:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($status);
}


=head2 query_task_details

  $details = $obj->query_task_details($task_id)

=over 4


=item Parameter and return types

=begin html

<pre>
$task_id is a task_id
$details is a TaskDetails
task_id is a string
TaskDetails is a reference to a hash where the following keys are defined:
	stdout_url has a value which is a string
	stderr_url has a value which is a string
	pid has a value which is an int
	hostname has a value which is a string
	exitcode has a value which is an int
</pre>

=end html

=begin text

$task_id is a task_id
$details is a TaskDetails
task_id is a string
TaskDetails is a reference to a hash where the following keys are defined:
	stdout_url has a value which is a string
	stderr_url has a value which is a string
	pid has a value which is an int
	hostname has a value which is a string
	exitcode has a value which is an int

=end text



=item Description


=back

=cut

sub query_task_details
{
    my $self = shift;
    my($task_id) = @_;

    my @_bad_arguments;
    (!ref($task_id)) or push(@_bad_arguments, "Invalid type for argument \"task_id\" (value was \"$task_id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to query_task_details:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($details);
    #BEGIN query_task_details

    if ($task_id !~ /^[A-Za-z0-9_-]+$/)
    {
	die "Invalid task ID";
    }
    
    my $tdir = "$self->{task_status_dir}/$task_id";
    
    $details = {
	stdout_url => "$self->{service_url}/task_info/$task_id/stdout",
	stderr_url => "$self->{service_url}/task_info/$task_id/stderr",
    };

    for my $f (qw(pid hostname exitcode))
    {
	my $d = read_file("$tdir/$f", err_mode => 'quiet');
	if (defined($d))
	{
	    chomp $d;
	    $details->{$f} = $d;
	}
    }

    #END query_task_details
    my @_bad_returns;
    (ref($details) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"details\" (value was \"$details\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_task_details:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($details);
}


=head2 enumerate_tasks

  $return = $obj->enumerate_tasks($offset, $count)

=over 4


=item Parameter and return types

=begin html

<pre>
$offset is an int
$count is an int
$return is a reference to a list where each element is a Task
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string
</pre>

=end html

=begin text

$offset is an int
$count is an int
$return is a reference to a list where each element is a Task
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	parent_id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
	user_id has a value which is a string
	status has a value which is a task_status
	awe_status has a value which is a task_status
	submit_time has a value which is a string
	start_time has a value which is a string
	completed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string

=end text



=item Description


=back

=cut

sub enumerate_tasks
{
    my $self = shift;
    my($offset, $count) = @_;

    my @_bad_arguments;
    (!ref($offset)) or push(@_bad_arguments, "Invalid type for argument \"offset\" (value was \"$offset\")");
    (!ref($count)) or push(@_bad_arguments, "Invalid type for argument \"count\" (value was \"$count\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to enumerate_tasks:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($return);
    #BEGIN enumerate_tasks

    my $awe = Bio::KBase::AppService::Awe->new($self->{awe_server}, $ctx->token);

    $return = [];

    #
    # TODO: paging of requests
    #

    my $q = "/job?query&info.user=" . $ctx->user_id . "&info.pipeline=AppService&limit=$count&offset=$offset";
    # print STDERR "Query tasks: $q\n";
    my ($res, $error) = $awe->GET($q);
    if ($res)
    {
	for my $t (@{$res->{data}})
	{
	    my $r = $self->_awe_to_task($t);
	    push(@$return, $r);
	}
    }
    else
    {
	die "Query '$q' failed: $error\n";
    }

    #END enumerate_tasks
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_tasks:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($return);
}


=head2 kill_task

  $killed, $msg = $obj->kill_task($id)

=over 4


=item Parameter and return types

=begin html

<pre>
$id is a task_id
$killed is an int
$msg is a string
task_id is a string
</pre>

=end html

=begin text

$id is a task_id
$killed is an int
$msg is a string
task_id is a string

=end text



=item Description


=back

=cut

sub kill_task
{
    my $self = shift;
    my($id) = @_;

    my @_bad_arguments;
    (!ref($id)) or push(@_bad_arguments, "Invalid type for argument \"id\" (value was \"$id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to kill_task:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($killed, $msg);
    #BEGIN kill_task

    #
    # Given the task ID, invoke AWE to nuke it.
    #
    # This is an AWE instance with the user's access.
    #
    my $user_awe = Bio::KBase::AppService::Awe->new($self->{awe_server}, $ctx->token);

    my($res, $err) = $user_awe->kill_job($id);

    print STDERR "Awe killed job $id: res=$res err=$err\n";
    if ($res)
    {
	$killed = 1;
	$msg = $res;
    }
    else
    {
	$killed = 0;
	$msg = $err;
    }
    
    #END kill_task
    my @_bad_returns;
    (!ref($killed)) or push(@_bad_returns, "Invalid type for return variable \"killed\" (value was \"$killed\")");
    (!ref($msg)) or push(@_bad_returns, "Invalid type for return variable \"msg\" (value was \"$msg\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to kill_task:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($killed, $msg);
}


=head2 rerun_task

  $new_task = $obj->rerun_task($id)

=over 4


=item Parameter and return types

=begin html

<pre>
$id is a task_id
$new_task is a task_id
task_id is a string
</pre>

=end html

=begin text

$id is a task_id
$new_task is a task_id
task_id is a string

=end text



=item Description


=back

=cut

sub rerun_task
{
    my $self = shift;
    my($id) = @_;

    my @_bad_arguments;
    (!ref($id)) or push(@_bad_arguments, "Invalid type for argument \"id\" (value was \"$id\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to rerun_task:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($new_task);
    #BEGIN rerun_task

    #
    # Rerun this task. We need to look up the app id, parameters, and workspace from
    # the AWE database.
    #

    my $awe = Bio::KBase::AppService::Awe->new($self->{awe_server}, $ctx->token);
    my $task = $self->_lookup_task($awe, $id);

    my $app = $task->{app};
    my $params = $task->{parameters};
    my $workspace = $task->{workspace};

    my $new_task_info = eval { $self->start_app($app, $params, $workspace); } ;

    if (ref($new_task_info))
    {
	$new_task = $new_task_info->{id};
	print "Started: new_task = $new_task\n";
	print Dumper($new_task_info);
    }
    else
    {
	die "Error starting new task: $@\n";
    }
    
    #END rerun_task
    my @_bad_returns;
    (!ref($new_task)) or push(@_bad_returns, "Invalid type for return variable \"new_task\" (value was \"$new_task\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to rerun_task:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($new_task);
}





=head2 version 

  $return = $obj->version()

=over 4

=item Parameter and return types

=begin html

<pre>
$return is a string
</pre>

=end html

=begin text

$return is a string

=end text

=item Description

Return the module version. This is a Semantic Versioning number.

=back

=cut

sub version {
    return $VERSION;
}



=head1 TYPES



=head2 task_id

=over 4


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 app_id

=over 4


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 workspace_id

=over 4


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 task_parameters

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the key is a string and the value is a string
</pre>

=end html

=begin text

a reference to a hash where the key is a string and the value is a string

=end text

=back



=head2 AppParameter

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is a string
label has a value which is a string
required has a value which is an int
default has a value which is a string
desc has a value which is a string
type has a value which is a string
enum has a value which is a string
wstype has a value which is a string

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is a string
label has a value which is a string
required has a value which is an int
default has a value which is a string
desc has a value which is a string
type has a value which is a string
enum has a value which is a string
wstype has a value which is a string


=end text

=back



=head2 App

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is an app_id
script has a value which is a string
label has a value which is a string
description has a value which is a string
parameters has a value which is a reference to a list where each element is an AppParameter

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is an app_id
script has a value which is a string
label has a value which is a string
description has a value which is a string
parameters has a value which is a reference to a list where each element is an AppParameter


=end text

=back



=head2 task_status

=over 4


=item Definition

=begin html

<pre>
a string
</pre>

=end html

=begin text

a string

=end text

=back



=head2 Task

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is a task_id
parent_id has a value which is a task_id
app has a value which is an app_id
workspace has a value which is a workspace_id
parameters has a value which is a task_parameters
user_id has a value which is a string
status has a value which is a task_status
awe_status has a value which is a task_status
submit_time has a value which is a string
start_time has a value which is a string
completed_time has a value which is a string
stdout_shock_node has a value which is a string
stderr_shock_node has a value which is a string

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is a task_id
parent_id has a value which is a task_id
app has a value which is an app_id
workspace has a value which is a workspace_id
parameters has a value which is a task_parameters
user_id has a value which is a string
status has a value which is a task_status
awe_status has a value which is a task_status
submit_time has a value which is a string
start_time has a value which is a string
completed_time has a value which is a string
stdout_shock_node has a value which is a string
stderr_shock_node has a value which is a string


=end text

=back



=head2 TaskResult

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is a task_id
app has a value which is an App
parameters has a value which is a task_parameters
start_time has a value which is a float
end_time has a value which is a float
elapsed_time has a value which is a float
hostname has a value which is a string
output_files has a value which is a reference to a list where each element is a reference to a list containing 2 items:
0: (output_path) a string
1: (output_id) a string


</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is a task_id
app has a value which is an App
parameters has a value which is a task_parameters
start_time has a value which is a float
end_time has a value which is a float
elapsed_time has a value which is a float
hostname has a value which is a string
output_files has a value which is a reference to a list where each element is a reference to a list containing 2 items:
0: (output_path) a string
1: (output_id) a string



=end text

=back



=head2 StartParams

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
parent_id has a value which is a task_id
workspace has a value which is a workspace_id

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
parent_id has a value which is a task_id
workspace has a value which is a workspace_id


=end text

=back



=head2 TaskDetails

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
stdout_url has a value which is a string
stderr_url has a value which is a string
pid has a value which is an int
hostname has a value which is a string
exitcode has a value which is an int

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
stdout_url has a value which is a string
stderr_url has a value which is a string
pid has a value which is an int
hostname has a value which is a string
exitcode has a value which is an int


=end text

=back


=cut

1;
