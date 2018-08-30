package Bio::KBase::AppService::Scheduler;

use 5.010;
use strict;
use Bio::KBase::AppService::Schema;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_user sched_db_pass sched_db_name);
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use JSON::XS;

__PACKAGE__->mk_accessors(qw(schema specs json));

sub new
{
    my($class, %opts) = @_;

    my $schema = Bio::KBase::AppService::Schema->connect("dbi:mysql:" . sched_db_name . ";host=" . sched_db_host,
							 sched_db_user, sched_db_pass);
    $schema or die "Cannot connect to database: " . Bio::KBase::AppService::Schema->errstr;
    $schema->storage->ensure_connected();
    my $self = {
	schema => $schema,
	json => JSON::XS->new->pretty(1)->canonical(1),
	%opts,
    };

    return bless $self, $class;
}

=head2 Methods

=over 4

=item B<start_app>

    $sched->start_app($app_id, $task-parameters, $start_parameters)

Start the given app. Validates the app ID and creates the scheduler record
for it, in state Submitted. Registers an idle event for a task-start check.

=cut

sub start_app
{
    my($self, $app_id, $task_parameters, $start_parameters) = @_;

    my $app = $self->find_app($app_id);

    #
    # Create our task.
    #

    my $code = $self->schema->resultset('TaskState')->find({description => 'Submitted'});
    
    my $task = $self->schema->resultset('Task')->create({
	parent_task => $start_parameters->{parent_id},
	state_code => $code,
	application_id => $app_id,
	submit_time => DateTime->now(),
	params => $self->json->encode($task_parameters),
    });

    say "Created task " . $task->id;
    return $task;
}

=item B<find_app>

Find this app in the database. If it is not there, use the AppSpecs instance
to find the spec file in the filesystem. If that is not there, fail.

    $app = $sched->find_app($app_id)

We return an Application result object.

=cut

sub find_app
{
    my($self, $app_id) = @_;

    my $coderef = sub {

	my $rs = $self->schema->resultset('Application')->find($app_id);
	return $rs if $rs;
	
	my $app = $self->specs->find($app_id);
	if (!$app)
	{
	    die "Unable to find application '$app_id'";
	}

	#
	# Construct our new app record.
	#
	$rs = $self->schema->resultset('Application')->create( {
	    id => $app->{id},
	    script => $app->{script},
	});

	return $rs;
    };

    my $rs;
    try {
	$rs = $self->schema->txn_do($coderef);
    } catch {
	my $error = shift;
	die "Failure creating app: $error";
    };
    return $rs;
	
}

=back

=cut    


1;
