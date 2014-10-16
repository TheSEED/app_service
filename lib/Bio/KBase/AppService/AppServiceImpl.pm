package Bio::KBase::AppService::AppServiceImpl;
use strict;
use Bio::KBase::Exceptions;
# Use Semantic Versioning (2.0.0-rc.1)
# http://semver.org 
our $VERSION = "0.1.0";

=head1 NAME

AppService

=head1 DESCRIPTION



=cut

#BEGIN_HEADER

use JSON::XS;
use Data::Dumper;
use Bio::KBase::AppService::Awe;
use Bio::KBase::AppService::Util;
use Bio::KBase::DeploymentConfig;
use File::Slurp;


#END_HEADER

sub new
{
    my($class, @args) = @_;
    my $self = {
    };
    bless $self, $class;
    #BEGIN_CONSTRUCTOR

    my $cfg = Bio::KBase::DeploymentConfig->new($ENV{KB_SERVICE_NAME} || "AppService");
    my $awe_server = $cfg->setting("awe-server");
    $self->{awe_server} = $awe_server;
    my $app_dir = $cfg->setting("app-directory");
    $self->{app_dir} = $app_dir;

    $self->{util} = Bio::KBase::AppService::Util->new($self);
	
    #END_CONSTRUCTOR

    if ($self->can('_init_instance'))
    {
	$self->_init_instance();
    }
    return $self;
}

=head1 METHODS



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

    push(@$return $self->{util}->enumerate_apps();
    
    #END enumerate_apps
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_apps:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'enumerate_apps');
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
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
task_id is a string

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
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
task_id is a string


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
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'start_app');
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($task);
    #BEGIN start_app

    #
    # Create a new workflow for this task.
    #

    my $awe = Bio::KBase::NarrativeService::Awe->new($self->{awe_server}, $ctx->token);

    my $userattr = {
	app_id => $app_id,
	parameters => encode_json($params),
	workspace => $workspace,
    };
	
    my $job = $awe->create_job_description(pipeline => 'NarrativeService',
					   name => $app_id,
					   project => 'NarrativeService',
					   user => $ctx->user_id,
					   clientgroups => '',
					   userattr => $userattr,
					  );
    #
    # The real code would walk through the app definition creating tasks for
    # each step. Here we just create one for grins.
    #

    my $task_userattr = {};
    my $task_id = $job->add_task("all_entities_Genome",
				 "all_entities_Genome",
				 "",
				 [],
				 [],
				 [],
				 undef,
				 undef,
				 $awe,
				 $task_userattr,
				);

    print STDERR Dumper($job);

    my $task_id = $awe->submit($job);

    $task = {
	id => $task_id,
	app_id => $app_id,
	workspace => $workspace,
	parameters => $params,
    };
    #END start_app
    my @_bad_returns;
    (ref($task) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"task\" (value was \"$task\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to start_app:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'start_app');
    }
    return($task);
}




=head2 query_task_status

  $status = $obj->query_task_status($tasks)

=over 4

=item Parameter and return types

=begin html

<pre>
$tasks is a reference to a list where each element is a task_id
$status is a reference to a hash where the key is a task_id and the value is a task_status
task_id is a string
task_status is a reference to a hash where the key is a string and the value is a string

</pre>

=end html

=begin text

$tasks is a reference to a list where each element is a task_id
$status is a reference to a hash where the key is a task_id and the value is a task_status
task_id is a string
task_status is a reference to a hash where the key is a string and the value is a string


=end text



=item Description



=back

=cut

sub query_task_status
{
    my $self = shift;
    my($tasks) = @_;

    my @_bad_arguments;
    (ref($tasks) eq 'ARRAY') or push(@_bad_arguments, "Invalid type for argument \"tasks\" (value was \"$tasks\")");
    if (@_bad_arguments) {
	my $msg = "Invalid arguments passed to query_task_status:\n" . join("", map { "\t$_\n" } @_bad_arguments);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'query_task_status');
    }

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($status);
    #BEGIN query_task_status
    #END query_task_status
    my @_bad_returns;
    (ref($status) eq 'HASH') or push(@_bad_returns, "Invalid type for return variable \"status\" (value was \"$status\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to query_task_status:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'query_task_status');
    }
    return($status);
}




=head2 enumerate_tasks

  $return = $obj->enumerate_tasks()

=over 4

=item Parameter and return types

=begin html

<pre>
$return is a reference to a list where each element is a Task
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
task_id is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string

</pre>

=end html

=begin text

$return is a reference to a list where each element is a Task
Task is a reference to a hash where the following keys are defined:
	id has a value which is a task_id
	app has a value which is an app_id
	workspace has a value which is a workspace_id
	parameters has a value which is a task_parameters
task_id is a string
app_id is a string
workspace_id is a string
task_parameters is a reference to a hash where the key is a string and the value is a string


=end text



=item Description



=back

=cut

sub enumerate_tasks
{
    my $self = shift;

    my $ctx = $Bio::KBase::AppService::Service::CallContext;
    my($return);
    #BEGIN enumerate_tasks
    #END enumerate_tasks
    my @_bad_returns;
    (ref($return) eq 'ARRAY') or push(@_bad_returns, "Invalid type for return variable \"return\" (value was \"$return\")");
    if (@_bad_returns) {
	my $msg = "Invalid returns passed to enumerate_tasks:\n" . join("", map { "\t$_\n" } @_bad_returns);
	Bio::KBase::Exceptions::ArgumentValidationError->throw(error => $msg,
							       method_name => 'enumerate_tasks');
    }
    return($return);
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



=head2 Task

=over 4



=item Definition

=begin html

<pre>
a reference to a hash where the following keys are defined:
id has a value which is a task_id
app has a value which is an app_id
workspace has a value which is a workspace_id
parameters has a value which is a task_parameters

</pre>

=end html

=begin text

a reference to a hash where the following keys are defined:
id has a value which is a task_id
app has a value which is an app_id
workspace has a value which is a workspace_id
parameters has a value which is a task_parameters


=end text

=back



=head2 task_status

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



=cut

1;
