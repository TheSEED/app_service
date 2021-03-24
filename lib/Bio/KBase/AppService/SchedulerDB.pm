package Bio::KBase::AppService::SchedulerDB;

use strict;
use 5.010;
use DBI;
use AnyEvent;
use AnyEvent::DBI::MySQL;
use DateTime::Format::MySQL;
use DateTime::Format::DateParse;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name
					 app_directory app_service_url);
use Scope::Guard;
use JSON::XS;
use base 'Class::Accessor';
use Data::Dumper;

#
# Simple wrapper class around the scheduler DB. Used when performance
# is important.
#

__PACKAGE__->mk_accessors(qw(dbh json dsn user pass));

sub new
{
    my($class) = @_;

    my $port = sched_db_port // 3306;

    my $dsn = "dbi:mysql:" . sched_db_name . ";host=" . sched_db_host . ";port=$port";
    my $self = {
	user => sched_db_user,
	pass => sched_db_pass,
	dsn => $dsn,
	json => JSON::XS->new->pretty(1)->canonical(1),
	state_code_cache => {},
    };
    return bless $self, $class;
}

sub dbh
{
    my($self) = @_;
    return $self->{dbh} if $self->{dbh};
    
    my $dbh =  $self->{dbh} = DBI->connect($self->dsn, $self->user, $self->pass, { AutoCommit => 1, RaiseError => 1 });
    $dbh or die "Cannot connect to database: " . $DBI::errstr;
    $dbh->do(qq(SET time_zone = "+00:00"));
    return $dbh;
}

#
# Create an Async handle if needed.
#
sub async_dbi
{
    my($self) = @_;
    # Don't cache. This lets us have multiple handles flowing.
    #return $self->{async} if $self->{async};

    print STDERR "asycn create\n";
    my $cv = AnyEvent->condvar;
    my $async;
    $async = new AnyEvent::DBI($self->dsn, $self->user, $self->pass,
				  PrintError => 0,
				  on_error => sub { print STDERR "ERROR on new @_\n"},
				  on_connect => sub {
				      my($dbh, $ok) = @_;
				      print STDERR "on conn  ok=$ok\n";
				      #
				      # Force timezone
				      #
				      $async->exec(qq(SET time_zone = "+00:00"), sub {
					  print STDERR "On conn\n";
					  $cv->send;
				      });
				  });
					       
    print STDERR "Wait for conn\n";
    $cv->wait;
    print STDERR "connected\n";
    #$self->{async} = $async;
    return $async;
}

sub async_mysql
{
    my($self) = @_;

    my $async = AnyEvent::DBI::MySQL->connect($self->dsn, $self->user, $self->pass);

    return $async;
}
*async = *async_mysql;

#
# Lazily load requirement for DBIx::Class and create the schema object.
#
sub schema
{
    my($self) = @_;
    return $self->{schema} if $self->{schema};

    require Bio::KBase::AppService::Schema;
    my $port = sched_db_port // 3306;

    my $extra = {
	on_connect_do => qq(SET time_zone = "+00:00"),
    };
    
    my $schema = Bio::KBase::AppService::Schema->connect($self->dsn, $self->user, $self->pass, undef, $extra);

    $schema or die "Cannot connect to database: " . Bio::KBase::AppService::Schema->errstr;

    $self->{schema} = $schema;
    return $schema;

}

sub begin_work
{
    my($self) = @_;
    $self->dbh->begin_work if $self->dbh->{AutoCommit};
}

sub commit
{
    my($self) = @_;
    $self->dbh->commit;
}

sub rollback
{
    my($self) = @_;
    $self->dbh->rollback;
}

sub create_task
{
    my($self, $token, $app_id, $monitor_url, $task_parameters, $start_parameters, $preflight) = @_;

    my $override_user = $start_parameters->{user_override};

    my $guard = Scope::Guard->new(sub {
	warn "create_task: rolling back transaction\n";
	$self->rollback();
    });

    $self->begin_work();
    
    my $app = $self->find_app($app_id);
    my $user = $self->find_user($override_user // $token->user_id, $token);

    #
    # Create our task.
    #

    my $res = $self->dbh->selectcol_arrayref(qq(SELECT code FROM TaskState WHERE description = ?), undef, 'Queued');
    if (@$res != 1)
    {
	die "Error retriving task code";
    }
    my $code = $res->[0];

    my $policy_data;

    my $container_id = $self->determine_container_id_override($task_parameters, $start_parameters);
    
    my $task = {
	owner => $user->{id},
	base_url => $start_parameters->{base_url},
	parent_task => $start_parameters->{parent_id},
	state_code => $code,
	application_id => $app_id,
	params => $self->json->encode($task_parameters),
	(ref($task_parameters) eq 'HASH' ?
	 (output_path => $task_parameters->{output_path},
	  output_file => $task_parameters->{output_file}) : ()),
	app_spec => $app->{spec},
	monitor_url => $monitor_url,
	req_memory => $preflight->{memory},
	req_cpu => $preflight->{cpu},
	req_runtime => $preflight->{runtime},
	req_policy_data => $self->json->encode($preflight->{policy_data} // {}),
	req_is_control_task => ($preflight->{is_control_task} ? 1 : 0),
	(defined($container_id) ? (container_id => $container_id) : ()),
	};

    my $fields = join(", ", keys %$task);
    my $qs = join(", ", map { "?" } keys %$task);
    my $res = $self->dbh->do(qq(INSERT INTO Task (submit_time, $fields) VALUES (CURRENT_TIMESTAMP(), $qs)), undef, values %$task);
    if ($res != 1)
    {
	die "Failed to insert task";
    }
    my $id = $self->dbh->last_insert_id(undef, undef, 'Task', 'id');

    $task->{id} = $id;

    $res = $self->dbh->do(qq(INSERT INTO TaskToken (task_id, token, expiration)
			     VALUES (?, ?, FROM_UNIXTIME(?))), undef,
			  $id, $token->token, $token->expiry);
    if ($res != 1)
    {
	die "Failed to insert TaskToken";
    }
    
    $guard->dismiss(1);
    $self->commit();
    return $task;
}

=head2 determine_container_id_override

Determine if the given task_params and start_params includes an explicit container_id override.

In order, examine

    $task_params->{container_id}
    $start_params->{container_id}

=cut

sub determine_container_id_override
{
    my($self, $task_params, $start_params) = @_;

    return $task_params->{container_id} // $start_params->{container_id};
}
    
#
# For the given cluster, determine if there is a default container.
# If so return its ID and pathname
#
sub cluster_default_container
{
    my($self, $cluster_name) = @_;

    my $res = $self->dbh->selectrow_arrayref(qq(
						SELECT cl.container_repo_url, cl.default_container_id, cl.container_cache_dir, c.filename
						FROM Cluster cl JOIN Container c ON cl.default_container_id = c.id
						WHERE cl.id = ?), undef, $cluster_name);
    if (!$res || @$res == 0)
    {
	warn "No container found for cluster $cluster_name\n";
	return undef;
    }
    my($url, $container_id, $cache, $filename) = @$res;

    return ($url, $container_id, $cache, $filename);
}    

#
# Look up the given container id.
#
sub find_container
{
    my($self, $container_id) = @_;

    my $res = $self->dbh->selectrow_arrayref(qq(SELECT c.filename
						FROM Container c 
						WHERE c.id = ?), undef, $container_id);
    if (!$res || @$res == 0)
    {
	warn "No container found for id $container_id\n";
	return undef;
    }
    return $res->[0];
}    

sub find_user
{
    my($self, $userid) = @_;

    my($base, $domain) = $userid =~ /(.*)\@([^@]+)$/;
    if ($domain eq '')
    {
	$domain = 'rast.nmpdr.org';
	$userid = "$userid\@$domain";
    }

    my $res = $self->dbh->selectrow_hashref(qq(SELECT * FROM ServiceUser WHERE id = ?), undef, $userid);

    return $res if $res;

    my $res = $self->dbh->selectcol_arrayref(qq(SELECT id FROM Project WHERE userid_domain = ?), undef, $domain);
    if (@$res == 0)
    {
	die "Unknown user domain $domain\n";
    }
    my $proj_id = $res->[0];

    $self->dbh->do(qq(INSERT INTO ServiceUser (id, project_id) VALUES (?, ?)), undef, $userid, $proj_id);

    #
    # We used to have code that used the PATRIC user service to inflate the data.
    # It does not belong here; if we want fuller user data we should have a separate
    # offline thread to manage updates when needed.
    #
    # We also don't try to tell the cluster that there is a new user. When a job
    # is submitted we will get an error that hte usthe user is missing, so we
    # may use that to trigger a fuller update to the both the database and to
    # the cluster user configuration.
    #

    return { id => $userid, project_id => $proj_id };
}

=item B<find_app>

Find this app in the database. If it is not there, use the AppSpecs instance
to find the spec file in the filesystem. If that is not there, fail.

    $app = $sched->find_app($app_id)

We return an Application result object.

Assume that we are executing inside a transaction.

=cut

sub find_app
{
    my($self, $app_id, $specs) = @_;

    my $sth = $self->dbh->prepare(qq(SELECT * FROM Application WHERE id = ?));
    $sth->execute($app_id);
    my $obj = $sth->fetchrow_hashref();

    return $obj if $obj;

    if (!$specs)
    {
	die "App $app_id not in database and no specs were passed";
    }
    
    my $app = $specs->find($app_id);
    if (!$app)
    {
	die "Unable to find application '$app_id'";
    }

    my $spec = $self->json->encode($app);
    $self->dbh->do(qq(INSERT INTO Application (id, script, default_memory, default_cpu, spec)
		      VALUES (?, ?, ?, ?, ?)), undef,
		   $app_id,
		   $app->{script},
		   $app->{default_ram},
		   $app->{default_cpu},
		   $spec);
    
    return {
	id => $app_id,
	spec => $spec,
	default_cpu => $app->{default_cpu},
	default_memory => $app->{default_ram},
	script => $app->{script},
    };
}

sub query_tasks
{
    my($self, $user_id, $task_ids) = @_;

    my $id_list = join(", ", grep { /^\d+$/ } @$task_ids);
    return {} unless $id_list;

    my $sth = $self->dbh->prepare(qq(SELECT id, parent_task, application_id, params, owner, state_code,
				     if(submit_time = default(submit_time), "", submit_time) as submit_time,
				     if(start_time = default(start_time), "", start_time) as start_time,
				     if(finish_time = default(finish_time), "", finish_time) as finish_time,
				     service_status
				     FROM Task JOIN TaskState ON state_code = code
					       WHERE id IN ($id_list)
					       ORDER BY submit_time DESC));
    $sth->execute();
    my $ret = {};
    while (my $ent = $sth->fetchrow_hashref())
    {
	$ret->{$ent->{id}} = $self->format_task_for_service($ent);
    }

    return $ret;
}

=item B<query_task_summary>

Return a summary of the counts of the task types for the specified user.

=cut

sub query_task_summary
{
    my($self, $user_id) = @_;

    my $res = $self->dbh->selectall_arrayref(qq(SELECT count(id) as count, state_code
						FROM Task 
						WHERE owner = ?
						GROUP BY state_code), undef, $user_id);

    my $ret = {};
    $ret->{$self->state_code_name($_->[1])} = int($_->[0]) foreach @$res;

    return $ret;
}

sub state_code_name
{
    my($self, $code) = @_;
    my $name = $self->{state_code_cache}->{$code};
    if (!$name)
    {
	my $c = $self->{state_code_cache};
	my $res = $self->dbh->selectall_arrayref(qq(SELECT code, service_status FROM TaskState));
	$c->{$_->[0]} = $_->[1] foreach @$res;
	$name = $c->{$code};
	# print Dumper($res, $self);
    }
    return $name;
}

=item B<query_task_summary_async>

Return a summary of the counts of the task types for the specified user, asynchronous version.

=cut

sub query_task_summary_async
{
    my($self, $user_id, $cb) = @_;
    
    my $async = $self->async;
    $async->selectall_arrayref(qq(SELECT count(id) as count, state_code
				      FROM Task 
				      WHERE owner = ?
				      GROUP BY state_code), undef, $user_id, sub {
					  my($res) = @_;
					  my $ret = {};
					  $async;
					  $ret->{$self->state_code_name($_->[1])} = int($_->[0]) foreach @$res;
					  &$cb([$ret])});
}

=item B<query_app_summary>

Return a summary of the counts of the apps for the specified user, asynchronous version.

=cut

sub query_app_summary
{
    my($self, $user_id) = @_;
    
    my $res = $self->dbh->selectall_arrayref(qq(SELECT count(id) as count, application_id
						FROM Task 
						WHERE owner = ?
						GROUP BY application_id), undef, $user_id);
    
    my $ret = {};
    $ret->{$_->[1]} = int($_->[0]) foreach @$res;
    return $ret;
}

=item B<query_app_summary_async>

Return a summary of the counts of the apps for the specified user, asynchronous version.

=cut

sub query_app_summary_async
{
    my($self, $user_id, $cb) = @_;
    
    my $async = $self->async;
    $async->selectall_arrayref(qq(SELECT count(id) as count, application_id
				      FROM Task 
				      WHERE owner = ?
				      GROUP BY application_id), undef, $user_id, sub {
					  my($res) = @_;
					  $async;
					  my $ret = {};
					  $ret->{$_->[1]} = int($_->[0]) foreach @$res;
					  &$cb([$ret])});
}

=item B<enumerate_tasks>

Enumerate the given user's tasks.

=cut

sub enumerate_tasks
{
    my($self, $user_id, $offset, $count) = @_;

    my $sth = $self->dbh->prepare(qq(SELECT id, parent_task, application_id, params, owner,
				     service_status,
				     IF(submit_time=default(submit_time), '', DATE_FORMAT(submit_time, '%Y-%m-%dT%TZ')) as submit_time,
				     IF(start_time=default(start_time), '', DATE_FORMAT(start_time,  '%Y-%m-%dT%TZ')) as start_time,
				     IF(finish_time=default(finish_time), '', DATE_FORMAT(finish_time, '%Y-%m-%dT%TZ')) as finish_time,
				     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), finish_time - start_time, '') as elapsed_time

				     FROM Task JOIN TaskState on state_code = code
				     WHERE owner = ?
				     ORDER BY submit_time DESC
				     LIMIT ?
				     OFFSET ?));
    $sth->execute($user_id, $count, $offset);

    my $ret = [];
    while (my $task = $sth->fetchrow_hashref())
    {
	push(@$ret, $self->format_task_for_service($task));
    }
    return $ret;
}

=item B<enumerate_tasks_async>

Enumerate the given user's tasks, asynchronous version.

=cut

sub enumerate_tasks_async
{
    my($self, $user_id, $offset, $count, $cb) = @_;

    my $async = $self->async;
    my $prep_cb = sub {
	my($rv, $sth) = @_;
	$async;
	my $ret = [];
	while (my$ task = $sth->fetchrow_hashref())
	{
	    push(@$ret, $self->format_task_for_service($task));
	}
	&$cb([$ret]);
    };

    my $qry = qq(SELECT id, parent_task, application_id, params, owner,
				     service_status,
				     DATE_FORMAT(CONVERT_TZ(submit_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as submit_time,
				     DATE_FORMAT(CONVERT_TZ(start_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as start_time,
				     DATE_FORMAT(CONVERT_TZ(finish_time, \@\@session.time_zone, '+00:00'), '%Y-%m-%dT%TZ') as finish_time
				     FROM Task JOIN TaskState on state_code = code
				     WHERE owner = ?
				     ORDER BY submit_time DESC
				     LIMIT ?
				     OFFSET ?);
    my $sth = $async->prepare($qry);
    $sth->execute($user_id, $count, $offset, $prep_cb);
}

=item B<enumerate_tasks_filtered_async>

Enumerate the given user's tasks, asynchronous version.

The $simple_filter is a hash with keys start_time, end_time, app, search.

=cut

sub enumerate_tasks_filtered_async
{
    my($self, $user_id, $offset, $count, $simple_filter, $cb) = @_;

    my @cond;
    my @param;

    push(@cond, "owner = ?");
    push(@param, $user_id);

    if (my $t = $simple_filter->{start_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time >= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $t = $simple_filter->{end_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time <= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $app = $simple_filter->{app})
    {
	if ($app =~ /^[0-aA-Za-z]+$/)
	{
	    push(@cond, "t.application_id = ?");
	    push(@param, $app);
	}
    }

    if (my $st = $simple_filter->{status})
    {
	if ($st =~ /^[-0-aA-Za-z]+$/)
	{
	    push(@cond, "ts.service_status = ?");
	    push(@param, $st);
	}

    }
    if (my $search_text = $simple_filter->{search})
    {
	push(@cond, "MATCH t.search_terms AGAINST (?)");
	push(@param, $search_text);
    }
    
    my $cond = join(" AND ", map { "($_)" } @cond);

    my $ret_fields = "t.id, t.parent_task, t.application_id, t.params, t.owner, ";
    for my $x (qw(submit_time start_time finish_time))
    {
	$ret_fields .= "DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ') as $x, ";
    }
    $ret_fields .= "t.finish_time - t.start_time as elapsed_time, ts.service_status";

    my $qry = qq(SELECT $ret_fields
		 FROM Task t JOIN TaskState ts on t.state_code = ts.code
		 WHERE $cond
		 ORDER BY t.submit_time DESC
		 LIMIT ?
		 OFFSET ?);
    my $count_qry = qq(SELECT COUNT(t.id)
		       FROM Task t JOIN TaskState ts on t.state_code = ts.code
		       WHERE $cond);

    my $all_ret = [];
    my $cv = AnyEvent->condvar;

    my $async = $self->async;

    $cv->begin;
    
    my $enumerate_cb = sub {
	my($rv, $sth) = @_;
	print STDERR "outer query returns $rv\n";
	$async;			#  Hold lexical ref
	my $ret = [];
	while (my $task = $sth->fetchrow_hashref())
	{
	    push(@$ret, $self->format_task_for_service($task));
	}
	$all_ret->[0] = $ret;

	$cv->end();
    };

    my $sth = $async->prepare($qry);

    print STDERR "execute outer query $qry\n";
    $cv->begin();
    $sth->execute(@param, $count, $offset, $enumerate_cb);

    my $async2 = $self->async;

    my $count_cb = sub {
	my($rv, $sth) = @_;

	$async2;		# Hold lexical ref
	print STDERR "Inner query returns $rv\n";
	my $row = $sth->fetchrow_arrayref();
	print Dumper($row);
	$all_ret->[1] = int($row->[0]);
	$cv->end();
    };

    my $sth2 = $async2->prepare($count_qry);
    $cv->begin();
    $sth2->execute(@param, $count_cb);

    $cv->cb(sub { print "FINISH \n"; $cb->($all_ret); });
    $cv->end();
}

=item B<enumerate_tasks_filtered>

Enumerate the given user's tasks.

The $simple_filter is a hash with keys start_time, end_time, app, search.

=cut

sub enumerate_tasks_filtered
{
    my($self, $user_id, $offset, $count, $simple_filter, $cb) = @_;

    my @cond;
    my @param;

    push(@cond, "owner = ?");
    push(@param, $user_id);

    if (my $t = $simple_filter->{start_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time >= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $t = $simple_filter->{end_time})
    {
	my $dt = DateTime::Format::DateParse->parse_datetime($t);
	if ($dt)
	{
	    push(@cond, "t.submit_time <= ?");
	    push(@param, DateTime::Format::MySQL->format_datetime($dt));
	}
    }

    if (my $app = $simple_filter->{app})
    {
	if ($app =~ /^[0-aA-Za-z]+$/)
	{
	    push(@cond, "t.application_id = ?");
	    push(@param, $app);
	}
    }

    if (my $st = $simple_filter->{status})
    {
	if ($st =~ /^[-0-aA-Za-z]+$/)
	{
	    push(@cond, "ts.service_status = ?");
	    push(@param, $st);
	}

    }
    if (my $search_text = $simple_filter->{search})
    {
	push(@cond, "MATCH t.search_terms AGAINST (?)");
	push(@param, $search_text);
    }
    
    my $cond = join(" AND ", map { "($_)" } @cond);

    my $ret_fields = "t.id, t.parent_task, t.application_id, t.params, t.owner, ";
    for my $x (qw(submit_time start_time finish_time))
    {
	$ret_fields .= "IF($x = default($x), '', DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ')) as $x, ";
	# $ret_fields .= "DATE_FORMAT( CONVERT_TZ(`$x`, \@\@session.time_zone, '+00:00') ,'%Y-%m-%dT%TZ') as $x, ";
    }
    $ret_fields .= "if(t.finish_time != default(t.finish_time) and t.start_time != default(t.start_time), t.finish_time - t.start_time, '') as elapsed_time, ";
    # $ret_fields .= "t.finish_time - t.start_time as elapsed_time, ts.service_status";
    $ret_fields .= " ts.service_status";

    my $qry = qq(SELECT $ret_fields
		 FROM Task t JOIN TaskState ts on t.state_code = ts.code
		 WHERE $cond
		 ORDER BY t.submit_time DESC
		 LIMIT ?
		 OFFSET ?);
    my $count_qry = qq(SELECT COUNT(t.id)
		       FROM Task t JOIN TaskState ts on t.state_code = ts.code
		       WHERE $cond);

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare($qry);
    $sth->execute(@param, $count, $offset);

    my $tasks = [];
    while (my $task = $sth->fetchrow_hashref())
    {
	push(@$tasks, $self->format_task_for_service($task));
    }

    $sth = $dbh->prepare($count_qry);
    $sth->execute(@param);

    my $row = $sth->fetchrow_arrayref();
    print Dumper($row);
    my $count = int($row->[0]);

    return ($tasks, $count);
}

sub format_task_for_service
{
    my($self, $task) = @_;

    my $params = eval { decode_json($task->{params}) };
    if ($@)
    {
	# warn "Error parsing params for task $task->{id}: '$task->{params}'\n";
	$params = {};
    }
    #die Dumper($task);
    my $rtask = {
	id => $task->{id},
	parent_id  => $task->{parent_task},
	app => $task->{application_id},
	workspace => undef,
	parameters => $params,
	user_id => $task->{owner},
	status => $task->{service_status},
	submit_time => $task->{submit_time},
	start_time => $task->{start_time},
	completed_time => $task->{finish_time},
	elapsed_time => "" . $task->{elapsed_time},
    };
    return $rtask;
}

#
# Maintenance routines
#


#
# Reset a job back to queued status.
#

sub reset_job
{
    my($self, $job, $reset_params) = @_;

    my $res = $self->dbh->selectall_arrayref(qq(SELECT  t.state_code, t.owner, te.active
						FROM Task t,  TaskExecution te
						WHERE t.id = te.task_id AND
							id = ?), undef, $job);
    
    if (@$res)
    {
	my $skip;
	print STDERR "Job records for $job:\n";
	for my $ent (@$res)
	{
	    my($state, $owner, $active) = @$ent;
	    print STDERR "\t$state\t$owner\t$active\n";
	    if ($state eq 'Q')
	    {
		$skip++;
	    }
	}
	if ($skip)
	{
	    print STDERR "Job $job is already in state Q, not changing\n";
	    return;
	}
	my @params;
	my $reset;
	if ($reset_params)
	{
	    if ($reset_params->{time})
	    {
		push(@params, $reset_params->{time});
		$reset .= ", t.req_runtime = ?";
	    }
	    if ($reset_params->{memory})
	    {
		push(@params, $reset_params->{memory});
		$reset .= ", t.req_memory = ?";
	    }
	}
	
	my $res = $self->dbh->do(qq(UPDATE Task t,  TaskExecution te
				    SET t.state_code='Q', te.active = 0 $reset
				    WHERE t.id = te.task_id AND
				    	id = ?), undef,  @params, $job);
	print STDERR "Update returns $res\n";
    }
							    
}

1;
