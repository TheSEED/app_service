package Bio::KBase::AppService::Scheduler;

use 5.010;
use strict;
use P3AuthToken;
use Bio::KBase::AppService::SchedulerDB;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_user sched_db_pass sched_db_port sched_db_name
					 redis_host redis_port redis_db);
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use EV;
use AnyEvent;
use EV::Hiredis;
use LWP::UserAgent;
use JSON::XS;
use DateTime;
use DateTime::TimeZone;
use DateTime::Format::ISO8601::Format;
use DBIx::Class::ResultClass::HashRefInflator;

__PACKAGE__->mk_accessors(qw(schema specs json db
			     task_start_timer task_start_interval
			     queue_check_timer queue_check_interval
			     default_cluster policies
			     time_zone
			     completed_tasks
			     redis
			    ));

sub new
{
    my($class, %opts) = @_;

    my $port = sched_db_port // 3306;
    my $dsn = "dbi:mysql:" . sched_db_name . ";host=" . sched_db_host . ";port=$port";
    print STDERR "Connect to $dsn\n";

    #
    # Create a SchedulerDB to make raw DBI requests; it will also create us a schema
    # for ORM requests.
    #
    # It will die upon failure to connect.
    #
    my $sched_db = Bio::KBase::AppService::SchedulerDB->new();
    my $schema = $sched_db->schema();

    #
    # We also connect to redis to get immediate response to
    # jobs submission and job-complete notifications.
    #

    my $redis;
    my $cv;
    $cv = AnyEvent->condvar;
    $redis = EV::Hiredis->new(host => redis_host,
				(redis_port ? (port => redis_port) : ()),
				on_connect => sub {
				    print "Connect\n";
				    $redis->command("select", redis_db, sub {
					print  "select finished\n";
					$cv->send();
				    })
				    },);
    $cv->wait();
    print "redis ready\n";
    undef $cv;

    my $cmd_redis;
    $cv = AnyEvent->condvar;
    $cmd_redis = EV::Hiredis->new(host => redis_host,
				  (redis_port ? (port => redis_port) : ()),
				  on_connect => sub {
				      print "Connect\n";
				      $cmd_redis->command("select", redis_db, sub {
					  print  "cmd select finished\n";
					  $cv->send();
				      })
				      },);
    $cv->wait();
    print "cmd_redis ready\n";
    undef $cv;

    $schema->storage->ensure_connected();
    my $self = {
	schema => $schema,
	db => $sched_db,
	redis => $redis,
	cmd_redis => $cmd_redis,
	json => JSON::XS->new->pretty(1)->canonical(1),
	task_start_interval => 120,
	queue_check_interval => 120,
	time_zone => DateTime::TimeZone->new(name => 'UTC'),
	policies => [],
	completed_tasks => [],
	%opts,
    };

    $redis->command("subscribe", "task_submission",
		    sub {
			my($result, $error) = @_;
			if ($error)
			{
			    warn "Redis error on submit: $error\n";
			}
			else
			{
			    if (ref($result))
			    {
				my($what, $channel, $data) = @$result;
				print "Tasksub: what=$what data=$data\n";
				my $idle;
				$idle = AnyEvent->idle(cb => sub { undef $idle; $self->task_start_check(); });
			    }
			    else
			    {
				print STDERR "redis: $result\n";
			    }
			}
		    });
			
    $redis->command("subscribe", "task_completion",
		    sub {
			my($result, $error) = @_;
			if ($error)
			{
			    warn "Redis error on submit: $error\n";
			}
			else
			{
			    if (ref($result))
			    {
				my($what, $channel, $data) = @$result;
				if ($what eq 'message' && $data =~ /^\d+$/)
				{
				    $self->task_completion_seen($data);
				}
			    }
			    else
			    {
				print STDERR "redis: $result\n";
			    }
			}
		    });
			

    #
    # Set up for clean shutdown on signal receipt.
    #
    for my $sig (qw(INT HUP TERM))
    {
	$self->{sig}->{$sig} = AnyEvent->signal(signal => $sig, cb => sub { $self->shutdown(); });
    }

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

    $self->start_task_timer(0);
    $self->start_queue_timer(5);
}

sub start_task_timer
{
    my($self, $initial_timeout) = @_;
    $self->task_start_timer(undef);
    $self->task_start_timer(AnyEvent->timer(after => $initial_timeout,
					    interval => $self->task_start_interval,
					    cb => sub { $self->task_start_check() }));
}

sub start_queue_timer
{
    my($self, $initial_timeout) = @_;

    $self->queue_check_timer(undef);
    $self->queue_check_timer(AnyEvent->timer(after => $initial_timeout,
					    interval => $self->queue_check_interval,
					    cb => sub { $self->queue_check() }));
}

sub task_completion_seen
{
    my($self, $task) = @_;
    print STDERR "Scheduler notified of completed task $task, queue is @{$self->{completed_tasks}}\n";
    push @{$self->completed_tasks}, $task;
    #
    # If we have tasks backed up, process queue now. Otherwise
    # set our timer for shortly in the future.
    #
    if (@{$self->completed_tasks} > 3)
    {
	$self->start_queue_timer(0);
    }
    else
    {
	$self->start_queue_timer(2);
    }
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

    my $override_user = $start_parameters->{user_override};

    my $app = $self->find_app($app_id);
    my $user = $self->find_user($override_user // $token->user_id, $token);

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
	(ref($task_parameters) eq 'HASH' ?
	 (output_path => $task_parameters->{output_path},
	  output_file => $task_parameters->{output_file}) : ()),
	app_spec => $app->spec,
	monitor_url => $monitor_url,
	req_memory => $preflight->{memory},
	req_cpu => $preflight->{cpu},
	req_runtime => $preflight->{runtime},
	req_policy_data => $self->json->encode($preflight->{policy_data} // {}),
	req_is_control_task => ($preflight->{is_control_task} ? 1 : 0),
	search_terms => join(" ", $user->id, 'Queued', $code, 
			     (ref($task_parameters) eq 'HASH' ?
			      ($task_parameters->{output_path}, output_file => $task_parameters->{output_file}) : ()),
			     $app_id),

    });

    my $tt = $self->schema->resultset('TaskToken')->create({
	task_id => $task->id,
	token => $token->token,
	expiration => DateTime->from_epoch(epoch => $token->expiry, time_zone => $self->time_zone),
    }); 

    say "Created task " . $task->id;
    if (1)
    {
	# Don't do this; allow scheduler to batch runs
	my $idle;
	$idle = AnyEvent->idle(cb => sub { undef $idle; $self->task_start_check(); });
    }
    return $task;
}

=item B<load_apps>

Use the AppSpecs instance to preload (and update if necessary) the
Application table.

=cut

sub load_apps
{
    my($self) = @_;
    
    for my $app ($self->specs->enumerate())
    {
	my $record = {
	    id => $app->{id},
	    script => $app->{script},
	    default_memory => $app->{default_memory},
	    default_cpu => $app->{default_cpu},
	    spec => $self->json->encode($app),
	};
	my $rs = $self->schema->resultset('Application')->update_or_new($record);

	if ($rs->in_storage)
	{
	    print STDERR "App $app->{id} updated\n";
	}
	else
	{
	    print STDERR "New app record for $app->{id} created\n";
	    $rs->insert;
	}
	# print STDERR Dumper($record);
    }

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
	# print STDERR "create user $userid\n";

	my $proj = $self->schema->resultset("Project")->find({userid_domain => $domain});
	print STDERR "proj=$proj " . $proj->id . "\n";

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
	print STDERR "Created user " . $urec->id . " " . $urec->project_id . "\n";

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

    if ($self->{task_start_disable})
    {
	print STDERR "Task start disabled\n";
	return;
    }
    print STDERR "Task start check\n";

    #
    # A baseline fairness measure. Don't release more than 10 jobs at a time from a
    # single user into the scheduler on a single task-start pass.
    #
    # This is a crude measure, as we'll do this again each time through. It might help in
    # rate limiting very large submissions.
    #
    my $max_per_owner_release = 10;
    my %jobs_released_per_owner;

    my $cluster = $self->default_cluster;
    if (!$cluster->submission_allowed())
    {
	return;
    }
    my $cluster_id = $cluster->id;

    my $rs = $self->schema->resultset("Task")->search(
						    { state_code => 'Q' },
						    { order_by => { -asc => 'submit_time' } });

    #
    # Also query for the number of submitted jobs per user, and apply a limit there.
    # The returns here are the users who have too many jobs submitted already.
    #
    my $per_user_limit = 20;
    my $res = $self->db->dbh->selectall_arrayref(qq(SELECT t.owner, COUNT(t.id)
						    FROM Task t
						       JOIN TaskExecution te ON t.id = te.task_id
						       JOIN ClusterJob cj ON cj.id = te.cluster_job_id
						    WHERE t.state_code = 'S' AND cj.cluster_id = ?
						    GROUP BY t.owner
						    HAVING COUNT(t.id) > ?), undef, $cluster_id, $per_user_limit);

    my %user_restricted;
    for my $ent (@$res)
    {
	my($user, $count) = @$ent;
	print STDERR "User $user restricted due to $count jobs submitted\n";
	$user_restricted{$user} = 1;
    }

    my %warned;

    while (my $cand = $rs->next())
    {
	#
	# we use get_column here to avoid the ORM pulling the owner class; we just need the id.
	#
	my $owner = $cand->get_column("owner");
	
	if ($jobs_released_per_owner{$owner} > $max_per_owner_release)
	{
	    if (!$warned{$owner}++)
	    {
		warn "Skipping additional submissions for $owner\n";
	    }
	    next;
	}
	elsif ($user_restricted{$owner})
	{
	    if (!$warned{$owner}++)
	    {
		warn "Skipping additional submissions for $owner - restricted by jobs submitted\n";
	    }
	    next;
	}	    
	$jobs_released_per_owner{$owner}++;

	$cluster->submit_tasks([$cand]);
    }
    #
    # Invalidate cache for users that had jobs released.
    #
    $self->invalidate_user_cache($_) foreach keys %jobs_released_per_owner;
}

#
# Archival code for now. We are disabling bucketing of submissions until we finish the
# policy-plugin support.
#

sub task_start_check_bucketed
{
    my($self) = @_;

    if ($self->{task_start_disable})
    {
	print STDERR "Task start disabled\n";
	return;
    }
    print STDERR "Task start check\n";


    #
    # Until we get the real policy stuff in place, query available jobs and sort
    # by owner and requested runtime so we can bucket them together.
    #
    my $rs = $self->schema->resultset("Task")->search(
						    { state_code => 'Q' },
						    { order_by => { -asc => [qw/owner req_runtime/] } });
#						    { order_by => { -asc => 'submit_time' } });

#    print STDERR "Evaluate " . scalar(@jobs) . " jobs to be run\n";
    
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

 OUTER:
    # Disable bucketing for now.
    my $per_bucket = 1;
    my $tolerance = 0.10;
    #
    # Task bucket contains [$cand, $cluster] pairs. Submission
    # requires all elements to have the same owner and a requested runtime
    # within $tolerance of each other.
    #

    #
    # We also don't try to support multiple clusters here; this requires
    # more thought to support in the face of high job load.
    #
    my @bucket;
 CANDIDATE:
    while (my $cand = $rs->next())
    {
	say "Candidate: " . $cand->id;

	my $cluster = $self->default_cluster;

	# my @clusters = $self->find_clusters_for_task($cand);
	# if (!@clusters)
	# {
	#     warn "No cluster found to start task " . $cand->id . "\n";
	#     next;
	# }

	# for my $cluster (@clusters)
	{
	    if (!$cluster->submission_allowed())
	    {
		# print STDERR "Skipping submit for " . $cand->id . " on cluster " . $cluster->id . "\n";
		last CANDIDATE;
	    }
	    #
	    # We have chosen $cluster. See if we are bucketing and can submit in the current bucket. 
	    #
	    if ($per_bucket > 1)
	    {
		if (@bucket == 0)
		{
		    push(@bucket, [$cand, $cluster]);
		}
		else
		{
		    my $base = $bucket[0]->[0];
		    my $delta = abs($base->req_runtime - $cand->req_runtime);
		    my $tval = $base->req_runtime * $tolerance;
		    print $cand->id, " $delta $tval\n";
		    if ($cluster->id eq $bucket[0]->[1]->id &&
			$cand->owner->id eq $base->owner->id &&
			$delta < $base->req_runtime * $tolerance)
		    {
			push(@bucket,[$cand, $cluster]);
			
			if (@bucket >= $per_bucket)
			{
			    print STDERR "Submit 1\n";
			    my $ok = $self->submit_bucket(\@bucket);
			    @bucket = ();
			    if (!$ok)
			    {
				last OUTER;
			    }
			}
		    }
		    else
		    {
			print STDERR "Can't\n";
			# We can't add to this bucket. Submit it and push this entry
			# to a new one.
			print STDERR "Submit 2\n";
			my $ok = $self->submit_bucket(\@bucket);
			if (!$ok)
			{
			    @bucket = ();
			    last OUTER;
			}
			@bucket = ([$cand, $cluster]);
		    }
		}
	    }
	    else
	    {
		#
		# No bucketing. Just submit this job.
		#
		$self->submit_bucket([[$cand, $cluster]]);
	    }
	    last;		# Skip cluster selection.
	}
    }
    if (@bucket)
    {
	$self->submit_bucket(\@bucket);
    }
}

sub submit_bucket
{
    my($self, $bucket) = @_;
    print STDERR "Submit:\n";
    my $cluster = $bucket->[0]->[1];
    my @j = map { $_->[0] } @$bucket;

    for my $t (@j)
    {
	print join("\t", $t->id, $t->owner->id, $t->req_runtime), "\n";
    }

    my $ok = $cluster->submit_tasks(\@j);
    if ($ok)
    {
	say "Submitted\n";
    }
    else
    {
	warn "Error submitting to cluster\n";
    }	
    return $ok;
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
    @{$self->completed_tasks} = ();
    print STDERR "Queue check\n";
    for my $cluster (@{$self->clusters})
    {
	$cluster->queue_check();
    }
}

sub request_queue_check
{
    my($self) = @_;
    AnyEvent::postpone { $self->queue_check(); }
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
    return [$self->default_cluster // ()];
}

=item B<query_tasks>

Query the status of the selected tasks.

=cut

sub query_tasks
{
    my($self, $user_id, $task_ids) = @_;

    my $rs = $self->schema->resultset("Task")->search(
						  {
						      'me.id' => { -in => $task_ids },
						      owner => $user_id,
						  },
						  {
						      prefetch => ['state_code'],
						      order_by => { -desc => 'submit_time' },
						      select => [qw(id parent_task application_id params owner state_code.service_status),
							     { DATE_FORMAT => ['submit_time', "'%Y-%m-%dT%TZ'"] },
							     { DATE_FORMAT => ['start_time', "'%Y-%m-%dT%TZ'"] },
							     { DATE_FORMAT => ['finish_time', "'%Y-%m-%dT%TZ'"] },
							     ],
						      as => [qw(id parent_task application_id params owner
								state_code.service_status submit_time start_time finish_time )],
						      }
						     );
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    my $ret = {};
    while (my $task = $rs->next())
    {
	$ret->{$task->{id}} = $self->format_task_for_service($task);
    }
    return $ret;
}

=item B<query_task_summary>

Return a summary of the counts of the task types for the specified user.

=cut

sub query_task_summary
{
    my($self, $user_id) = @_;

    my $rs = $self->schema->resultset("Task")->search(
						  {
						      'me.owner' => $user_id,
						  },
						  {
						      prefetch => ['state_code'],
						      select => ['state_code.service_status',
							     { count => 'me.id', -as => 'count' } ],
						      group_by => ['state_code'],
						  }
						     );


    my $ret = {};
    while (my $item = $rs->next())
    {
	$ret->{$item->state_code->service_status} = $item->get_column('count');
    }
    return $ret;
}

=item B<enumerate_tasks>

Enumerate the given user's tasks.

=cut

sub enumerate_tasks
{
    my($self, $user_id, $offset, $count) = @_;

    my $rs = $self->schema->resultset("Task")->search(
						  {
						      'me.owner' => $user_id,
						  },
						  {
						      prefetch => ['state_code'],
						      order_by => { -desc => 'submit_time' },
						      rows => $count,
						      offset => $offset,
						      select => [qw(id parent_task application_id params owner state_code.service_status),
							     { DATE_FORMAT => ['submit_time', "'%Y-%m-%dT%TZ'"] },
							     { DATE_FORMAT => ['start_time', "'%Y-%m-%dT%TZ'"] },
							     { DATE_FORMAT => ['finish_time', "'%Y-%m-%dT%TZ'"] },
							     ],
						      as => [qw(id parent_task application_id params owner
								state_code.service_status submit_time start_time finish_time )],
						      }
						     );


    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    my $ret = [];
    while (my $task = $rs->next())
    {
	push(@$ret, $self->format_task_for_service($task));
    }
    return $ret;
}

sub format_task_for_service
{
    my($self, $task) = @_;

    my $params = eval { decode_json($task->{params}) };
    if ($@)
    {
	warn "Error parsing params for task $task->{id}: '$task->{params}'\n";
	$params = {};
    }

    my $rtask = {
	id => $task->{id},
	parent_id  => $task->{parent_task},
	app => $task->{application_id},
	workspace => undef,
	parameters => $params,
	user_id => $task->{owner},
	status => $task->{state_code}->{service_status},
	submit_time => "" . $task->{submit_time},
	start_time => "" . $task->{start_time},
	completed_time => "" . $task->{finish_time},
    };
    return $rtask;
}


=item B<kill_tasks>

Kill the given tasks.

This requires finding the active cluster the task is resident on; if the
task is marked as active there we forward the kill request to the cluster.

=cut

sub kill_tasks
{
    my($self, $user_id, $tasks) = @_;

    my $rs = $self->schema->resultset("Task")->search(
						  {
						      'me.owner' => $user_id,
						      'task_executions.active' => 1,
						      'me.id' => $tasks,
						  },
						  {
#						      join => { task_executions => 'cluster_job' },
						      prefetch => { task_executions => 'cluster_job' },
						  }
						     );


    my %to_kill = map { $_ => 1 } @$tasks;
    my $kill_status = {};
    
    while (my $ent = $rs->next())
    {
	my $task_id = $ent->id;
	my $killed;
	
	delete $to_kill{$task_id};
	my $te = ($ent->task_executions->all())[0];
	my $cj = $te->cluster_job;

	my $msg = "job=" . $cj->job_id . " status=" . $cj->job_status;

	my($cluster) = grep { $_->id eq $cj->cluster_id } @{$self->clusters()};
	if ($cluster)
	{
	    $cluster->kill_job($cj);
	    $killed = 1;
	}
	else
	{
	    warn "No cluster found for " . $cj->cluster_id . "\n";
	    $msg .= ": no cluster configured";
	    $killed = 0;
	}
	$kill_status->{$task_id} = { killed => $killed, msg => $msg };
    }
    for my $task_id (keys %to_kill)
    {
	$kill_status->{$task_id} = { killed => 0, msg => "task $task_id not found" };
    }
    return $kill_status;
}

=item B<shutdown>

Shutdown scheduler and exit.

=cut

sub shutdown
{
    my($self) = @_;
    #
    # Note we'll get a warning "here error:" from EV::Hiredis. However we want to ensure a shutdown
    # so we don't try to do clean disconnect (which gives us an error anyway).
    #
    warn "Shutting down\n";
    exit(0);
}

=item B<invalidate_user_cache>

Invalidate the user app service cache for the given user.
    
=cut

sub invalidate_user_cache
{
    my($self, $user) = @_;
    my $key = $user. ":app_service_cache";
    $self->{cmd_redis}->command("del", $key, sub {
	print STDERR "Cleared cache for $key\n";
    });
}

=back


=cut    



1;
