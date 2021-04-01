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

use Redis::Fast;
use Bio::KBase::AppService::AppConfig qw(redis_host redis_port redis_db);
use JSON::XS;
use MongoDB;
use Data::Dumper;
use Bio::KBase::AppService::Util;
use Bio::KBase::AppService::SchedulerDB;
use Bio::P3::DeploymentConfig;
use P3AuthToken;
use P3AuthLogin;
use P3TokenValidator;
use File::Slurp;
use Data::UUID;
use Plack::Request;
use IO::File;
use IO::Handle;
use MIME::Base64;
# use Carp::Always;

sub _redis_get_or_compute
{
    my($self, $user, $hkey, $code) = @_;

    my $val;
    my $key = $user . ":app_service_cache";
    my $val_txt = $self->{redis}->hget($key, $hkey);
    if ($val_txt)
    {
	$val = decode_json($val_txt);
	# print STDERR "From cache key=$key hkey=$hkey" . Dumper($val);
    }
    else
    {
	$val = &$code;
	$self->{redis}->hset($key, $hkey, encode_json($val), sub {});
	$self->{redis}->expire($key, 300, sub {});
	$self->{redis}->wait_all_responses();
	# print STDERR "computed " . Dumper($val);
    }
    return $val;

}

sub _task_info
{
    my($self, $env) = @_;
    my $req = Plack::Request->new($env);
    my $path = $req->path_info;
    # print STDERR "$path\n";
    # print STDERR Dumper($req);

    #
    # Ugly manual parsing of REST paths. If we do anything more complex this
    # should become a Dancer thing.
    #

    if ($path !~ s,^/+([a-zA-Z0-9_-]+)/,,)
    {
	return $req->new_response(404)->finalize();
    }
    my $task = $1;

    #
    # Authentication support.
    #
    # We require an auth token; failing that, we defer to HTTP basic
    # authentication.
    #

    my $auth = $req->header("Authorization");
    my $token;
    if ($auth =~ /^OAuth\s+(.*)$/i)
    {
	my $token_str = $1;
	$token = P3AuthToken->new(token => $token_str);
	my($ok,$msg) = $self->{token_validator}->validate($token);
	if (!$ok)
	{
	    print STDERR "Token did not validate: $msg\n";
	    return $req->new_response(500)->finalize();
	}
    }
    elsif ($auth =~ /^Basic\s+(.*)$/)
    {
	my $dec = decode_base64($1);
	my($user, $pw) = split(/:/, $dec, 2);
#	print STDERR "Got $user\n";
	eval {
	    my $token_str = P3AuthLogin::login_patric($user, $pw);
	    $token = P3AuthToken->new(token => $token_str);
	};
	if ($@)
	{
	    warn "Login failed: $@";
	}
    }

    if (!$token)
    {
	my $res = $req->new_response(401);
	$res->header("WWW-Authenticate", "Basic realm=\"PATRIC Login\"");
	return $res->finalize();
    }

    # print STDERR "Auth user=" . $token->user_id . " is-admin=" . $token->is_admin . "\n";

    #
    # Look up task record so we can authenticate.
    #
    my $task_obj = $self->{schema}->resultset("Task")->find({ id => $task },
							    {
								columnns => ['owner'],
								result_class => 'DBIx::Class::ResultClass::HashRefInflator',
							       });
    if (!$task_obj)
    {
	print STDERR "not found: $task\n";
	return $req->new_response(404)->finalize();
    }
    # print STDERR "Found task owner=" . $task_obj->{owner} . "\n";

    if (!(lc($task_obj->{owner}) eq lc($token->user_id) || $token->is_admin))
    {
	return $req->new_response(403)->finalize();
    }
    undef $task_obj;

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
		#
		# Use sed to strip the signatures from any tokens.
		#
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
	# POST /task/file/<tag>
	#
	# if <tag> = 'data', append to file
	# if <tag> = 'eof', mark eof
	#
	
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
	if ($file eq 'exitcode')
	{
	    print STDERR "have exitcode, trying queue check\n";
	    
	    # prod the scheduler. Fire & forget.
	    # $self->{redis}->command("publish", "task_completion", $task, sub { print STDERR "Publish complete\n";});
	    $self->{redis}->publish("task_completion", $task);
	}
	return $res->finalize();
    }
    else
    {
	return $req->new_response(404)->finalize();
    }
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
    my $app_dir = $cfg->setting("app-directory");
    $self->{app_dir} = $app_dir;

    $self->{redis_host} = $cfg->setting('redis-host') // 'localhost';
    $self->{redis_port} = $cfg->setting('redis-port') // 6379;
    $self->{redis_db} = $cfg->setting('redis-db') // 0;

    $self->{task_status_dir} = $cfg->setting("task-status-dir");
    $self->{service_url} = $cfg->setting("service-url");

    $self->{util} = Bio::KBase::AppService::Util->new($self);
    $self->{scheduler_db} = Bio::KBase::AppService::SchedulerDB->new();
    $self->{schema} = $self->{scheduler_db}->schema();

    $self->{status_file} = $cfg->setting("status-file");

    $self->{token_validator} = P3TokenValidator->new();


    #
    # Connect to redis
    #
    my $redis = Redis::Fast->new(reconnect => 1,
				 server => join(":", redis_host, redis_port),
				 );
    $redis->select(redis_db);
    $self->{redis} = $redis;

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

#    return sub {
#	my($cb) = @_;
#	print STDERR "Got cb=$cb\n";
#	$cb->($return);
#    };
    
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
	elapsed_time has a value which is a string
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
	elapsed_time has a value which is a string
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
    $task = $self->{util}->start_app_with_preflight_sync($ctx, $app_id, $params, { workspace => $workspace });
    
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
	base_url has a value which is a string
	container_id has a value which is a string
	user_metaata has a value which is a string
	reservation has a value which is a string
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
	elapsed_time has a value which is a string
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
	base_url has a value which is a string
	container_id has a value which is a string
	user_metaata has a value which is a string
	reservation has a value which is a string
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
	elapsed_time has a value which is a string
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
    # my $cb = $self->{util}->start_app_with_preflight($ctx, $app_id, $params, $start_params);
    # return $cb;
    $task = $self->{util}->start_app_with_preflight_sync($ctx, $app_id, $params, $start_params);

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
	elapsed_time has a value which is a string
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
	elapsed_time has a value which is a string
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

    $tasks = $self->{scheduler_db}->query_tasks($ctx->user_id, $task_ids);

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

    $status = $self->_redis_get_or_compute($ctx->user_id, 'query_task_summary',
					   sub { 
					       return $self->{scheduler_db}->query_task_summary($ctx->user_id);
					   });

    #END query_task_summary
    my @_bad_returns;
    (ref($status) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"status\" (value was \"$status\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_task_summary:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($status);
}


=head2 query_app_summary

  $status = $obj->query_app_summary()

=over 4


=item Parameter and return types

=begin html

<pre>
$status is a reference to a hash where the key is an app_id and the value is an int
app_id is a string
</pre>

=end html

=begin text

$status is a reference to a hash where the key is an app_id and the value is an int
app_id is a string

=end text



=item Description


=back

=cut

sub query_app_summary
{
    my $self = shift;

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($status);
    #BEGIN query_app_summary

    # $status = $self->{scheduler_db}->query_app_summary($ctx->user_id);
    $status = $self->_redis_get_or_compute($ctx->user_id, 'query_app_summary',
					  sub {
					      return $self->{scheduler_db}->query_app_summary($ctx->user_id);
					  });

    #END query_app_summary
    my @_bad_returns;
    (ref($status) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"status\" (value was \"$status\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_app_summary:\n" . join("", map { "\t$_\n" } @_bad_returns);
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
	elapsed_time has a value which is a string
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
	elapsed_time has a value which is a string
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

    $return = $self->_redis_get_or_compute($ctx->user_id, join(":", "enumerate_tasks", $offset, $count),
					  sub {
					      return $self->{scheduler_db}->enumerate_tasks($ctx->user_id, $offset, $count);
					  });

    # $return = $self->{scheduler_db}->enumerate_tasks($ctx->user_id, $offset, $count);

    #END enumerate_tasks
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_tasks:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($return);
}


=head2 enumerate_tasks_filtered

  $tasks, $total_tasks = $obj->enumerate_tasks_filtered($offset, $count, $simple_filter)

=over 4


=item Parameter and return types

=begin html

<pre>
$offset is an int
$count is an int
$simple_filter is a SimpleTaskFilter
$tasks is a reference to a list where each element is a Task
$total_tasks is an int
SimpleTaskFilter is a reference to a hash where the following keys are defined:
	start_time has a value which is a string
	end_time has a value which is a string
	app has a value which is an app_id
	search has a value which is a string
	status has a value which is a string
app_id is a string
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
	elapsed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string
</pre>

=end html

=begin text

$offset is an int
$count is an int
$simple_filter is a SimpleTaskFilter
$tasks is a reference to a list where each element is a Task
$total_tasks is an int
SimpleTaskFilter is a reference to a hash where the following keys are defined:
	start_time has a value which is a string
	end_time has a value which is a string
	app has a value which is an app_id
	search has a value which is a string
	status has a value which is a string
app_id is a string
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
	elapsed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
task_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string

=end text



=item Description


=back

=cut

sub enumerate_tasks_filtered
{
    my $self = shift;
    my($offset, $count, $simple_filter) = @_;

    my @_bad_arguments;
    (!ref($offset)) or push(@_bad_arguments, "Invalid type for argument \"offset\" (value was \"$offset\")");
    (!ref($count)) or push(@_bad_arguments, "Invalid type for argument \"count\" (value was \"$count\")");
    (ref($simple_filter) eq 'HASH') or push(@_bad_arguments, "Invalid type for argument \"simple_filter\" (value was \"$simple_filter\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to enumerate_tasks_filtered:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($tasks, $total_tasks);
    #BEGIN enumerate_tasks_filtered
    
    ($tasks, $total_tasks) = $self->{scheduler_db}->enumerate_tasks_filtered($ctx->user_id, $offset, $count, $simple_filter);

    #END enumerate_tasks_filtered
    my @_bad_returns;
    (ref($tasks) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"tasks\" (value was \"$tasks\")");
    (!ref($total_tasks)) or push(@_bad_returns, "Invalid type for return variable \"total_tasks\" (value was \"$total_tasks\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_tasks_filtered:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($tasks, $total_tasks);
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

    my $ret = $self->{util}->kill_tasks($ctx->user_id, [$id]);
    $killed = $ret->{$id}->{killed};
    $msg = $ret->{$id}->{msg};
    
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


=head2 kill_tasks

  $return = $obj->kill_tasks($ids)

=over 4


=item Parameter and return types

=begin html

<pre>
$ids is a reference to a list where each element is a task_id
$return is a reference to a hash where the key is a task_id and the value is a reference to a hash where the following keys are defined:
	killed has a value which is an int
	msg has a value which is a string
task_id is a string
</pre>

=end html

=begin text

$ids is a reference to a list where each element is a task_id
$return is a reference to a hash where the key is a task_id and the value is a reference to a hash where the following keys are defined:
	killed has a value which is an int
	msg has a value which is a string
task_id is a string

=end text



=item Description


=back

=cut

sub kill_tasks
{
    my $self = shift;
    my($ids) = @_;

    my @_bad_arguments;
    (ref($ids) eq 'ARRAY') or push(@_bad_arguments, "Invalid type for argument \"ids\" (value was \"$ids\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to kill_tasks:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	die $msg;
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($return);
    #BEGIN kill_tasks

    $return = $self->{util}->kill_tasks($ctx->user_id, $ids);

    #END kill_tasks
    my @_bad_returns;
    (ref($return) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to kill_tasks:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($return);
}


=head2 rerun_task

  $task = $obj->rerun_task($id)

=over 4


=item Parameter and return types

=begin html

<pre>
$id is a task_id
$task is a Task
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
	elapsed_time has a value which is a string
	stdout_shock_node has a value which is a string
	stderr_shock_node has a value which is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string
task_status is a string
</pre>

=end html

=begin text

$id is a task_id
$task is a Task
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
	elapsed_time has a value which is a string
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
    my($task);
    #BEGIN rerun_task

    #
    # Rerun this task. We need to look up the app id, parameters, and workspace from
    # the scheduler.
    #

    my $task_obj = $self->{schema}->resultset("Task")->find({ id => $id });
    
    my $app_id = $task_obj->application_id;
    my $params = decode_json($task_obj->params);
    my $workspace = "";

    # my $cb = $self->{util}->start_app_with_preflight($ctx, $app_id, $params, { workspace => $workspace });
    # return $cb;

    $task = $self->{util}->start_app_with_preflight_sync($ctx, $app_id, $params, { workspace => $workspace });
    
    #END rerun_task
    my @_bad_returns;
    (ref($task) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"task\" (value was \"$task\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to rerun_task:\n" . join("", map { "\t$_\n" } @_bad_returns);
	die $msg;
    }
    return($task);
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
elapsed_time has a value which is a string
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
elapsed_time has a value which is a string
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
base_url has a value which is a string
container_id has a value which is a string
user_metaata has a value which is a string
reservation has a value which is a string

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
parent_id has a value which is a task_id
workspace has a value which is a workspace_id
base_url has a value which is a string
container_id has a value which is a string
user_metaata has a value which is a string
reservation has a value which is a string


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



=head2 SimpleTaskFilter

=over 4


=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
start_time has a value which is a string
end_time has a value which is a string
app has a value which is an app_id
search has a value which is a string
status has a value which is a string

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
start_time has a value which is a string
end_time has a value which is a string
app has a value which is an app_id
search has a value which is a string
status has a value which is a string


=end text

=back


=cut

1;
