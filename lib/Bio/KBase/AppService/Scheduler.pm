package Bio::KBase::AppService::Scheduler;

use 5.010;
use strict;
use P3AuthToken;
use Bio::KBase::AppService::Schema;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_user sched_db_pass sched_db_name);
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use EV;
use AnyEvent;
use LWP::UserAgent;
use JSON::XS;
use DateTime;
use DateTime::TimeZone;

__PACKAGE__->mk_accessors(qw(schema specs json
			     task_start_timer task_start_interval
			     queue_check_timer queue_check_interval
			     default_cluster policies
			     time_zone
			    ));

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
	task_start_interval => 15,
	queue_check_interval => 60,
	time_zone => DateTime::TimeZone->new(name => 'UTC'),
	policies => [],
	%opts,
    };

    return bless $self, $class;
}

=head2 Methods

=over 4

=item B<start_timers>

    $sched->start_timers()

Start the asyncronous event timers.

=cut

sub start_timers
{
    my($self) = @_;

    $self->task_start_timer(AnyEvent->timer(after => 0,
					    interval => $self->task_start_interval,
					    cb => sub { $self->task_start_check() }));
    $self->queue_check_timer(AnyEvent->timer(after => $self->queue_check_interval,
					    interval => $self->queue_check_interval,
					    cb => sub { $self->queue_check() }));
}

=item B<start_app>

    $sched->start_app($token, $app_id, $monitor_url, $task_parameters, $start_parameters, $preflight)

=over 4

L<$token> is a P3AuthToken instance.

Start the given app. Validates the app ID and creates the scheduler record
for it, in state Submitted. Registers an idle event for a task-start check.

=cut

sub start_app
{
    my($self, $token, $app_id, $monitor_url, $task_parameters, $start_parameters, $preflight) = @_;

    my $app = $self->find_app($app_id);
    my $user = $self->find_user($token->user_id, $token);

    #
    # Create our task.
    #

    my $code = $self->schema->resultset('TaskState')->find({description => 'Queued'});
    
    my $policy_data;
    
    my $task = $self->schema->resultset('Task')->create({
	owner => $user->id,
	parent_task => $start_parameters->{parent_id},
	state_code => $code,
	application_id => $app_id,
	submit_time => DateTime->now(),
	params => $self->json->encode($task_parameters),
	app_spec => $app->spec,
	monitor_url => $monitor_url,
	req_memory => $preflight->{memory},
	req_cpu => $preflight->{cpu},
	req_runtime => $preflight->{runtime},
	req_policy_data => $self->json->encode($preflight->{policy_data} // {}),
    });

    my $tt = $self->schema->resultset('TaskToken')->create({
	task_id => $task->id,
	token => $token->token,
	expiration => DateTime->from_epoch(epoch => $token->expiry, time_zone => $self->time_zone),
    }); 

    say "Created task " . $task->id;
    my $idle;
    $idle = AnyEvent->idle(cb => sub { undef $idle; $self->task_start_check(); });
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
	    default_memory => $app->{default_ram},
	    default_cpu => $app->{default_cpu},
	    spec => $self->json->encode($app),
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

=item B<find_user>

Find this user in the database. We apply any rules (inline here) about mapping from
userids as found in tokens to the userids we will use in the scheduler.

Currently the only rule is that a userid in the token missing a @domain is mapped to
user@rast.nmpdr.org. The only other accepted userid is of the form user@patricbrc.org.

We create a userid in the database if one is not present. We also offer up the 
new user thus created to the underlying clusters so that they can create accounting
records if necessary.

Returns the database record for the user.

=cut

sub find_user
{
    my($self, $userid, $access_token) = @_;

    my($base, $domain) = split(/\@/, $userid, 2);
    if ($domain eq '')
    {
	$domain = 'rast.nmpdr.org';
	$userid = "$userid\@$domain";
    }

    my $urec = $self->schema->resultset("ServiceUser")->find($userid);
    if (!$urec)
    {
	# print "create user $userid\n";

	my $proj = $self->schema->resultset("Project")->find({userid_domain => $domain});
	print "proj=$proj " . $proj->id . "\n";

	#
	# Inline this for now. If this is a PATRIC user, try to expand
	# the user information based on the user service.
	#
	my $user_info = {};
	if ($access_token && $proj->id eq 'PATRIC')
	{
	    my $ua = LWP::UserAgent->new;
	    my $url = "https://user.patricbrc.org/user/$base";
	    my $res = $ua->get($url,
			       Accept => "application/json",
			       Authorization => (ref($access_token) ? $access_token->token : $access_token));
	    if ($res->is_success)
	    {
		$user_info = eval { $self->json->decode($res->content); };
		if ($user_info)
		{
		    if (ref($user_info) ne 'HASH')
		    {
			warn "Invalid userinfo for '$base' (not a hash); disregarding\n";
			$user_info = {};
		    }
		}
	    }
	}

	$urec = $proj->create_related('service_users',
				  {
				      id => $userid,
				      map { $_ => $user_info->{$_} } qw(first_name last_name email affiliation),
				  });
	print "Created user " . $urec->id . " " . $urec->project_id . "\n";

	#
	# Offer each of the clusters the chance to set up accounting for this user.
	#
	$_->configure_user($urec) foreach @{$self->clusters};
    }
    return $urec;
}

=item B<task_start_check>

Timer callback for determining tasks to be started.

We look for all jobs in state Q (Queued). Each of these is a candidate for starting on a cluster.

=cut

sub task_start_check
{
    my($self) = @_;
    print "Task start check\n";

    #
    # Allow any configured policies to have first stab at the queue.
    #

    for my $policy (@{$self->policies})
    {
	if ($policy->can("start_tasks"))
	{
	    $policy->start_tasks($self);
	}
    }
    

    my $rs = $self->schema->resultset("Task")->search(
						  { state_code => 'Q' },
						  { order_by => { -asc => 'submit_time' } });
    
    while (my $cand = $rs->next())
    {
	say "Candidate: " . $cand->id;

	my @clusters = $self->find_clusters_for_task($cand);
	if (!@clusters)
	{
	    warn "No cluster found to start task " . $cand->id . "\n";
	    next;
	}

	for my $cluster (@clusters)
	{
	    if ($cluster->submit_tasks([$cand]))
	    {
		say "Submitted";
		last;
	    }
	    else
	    {
		say "Could not submit " . $cand->id . " to cluster ". $cluster->id;
	    }
	}
    }
}

=item B<find_clusters_for_task>

Determine which if any clusters are appropriate for the given task.

For now, return our default cluster.

=cut

sub find_clusters_for_task
{
    my($self) = @_;
    return ($self->default_cluster);
}

=item B<queue_check>

Timer callback for checking queues for updates.

=cut

sub queue_check
{
    my($self) = @_;
    print "Queue check\n";
    for my $cluster (@{$self->clusters})
    {
	$cluster->queue_check();
    }
}


=item B<clusters>

Returns the list of configured clusters.

=cut

sub clusters
{
    my($self) = @_;

    #
    # For now we just have the default.
    #
    return [$self->default_cluster];
}

=back

=cut    


1;
