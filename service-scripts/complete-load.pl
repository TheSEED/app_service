use strict;
use Bio::KBase::AppService::SchedulerDB;
use Data::Dumper;

my $db = Bio::KBase::AppService::SchedulerDB->new;
my $dbh = $db->dbh;
my $sth = $dbh->prepare(qq(select id from ClusterJob where job_id = ? and cluster_id= 'P3AWE'));
my $isth = $dbh->prepare(qq(insert into TaskExecution(task_id, cluster_job_id, active) values (?, ?, 1)));
for my $ent (@{$dbh->selectall_arrayref(qq(select * from loader))})
{
    $dbh->begin_work;
    my($cj, $owner, $state, $app, $sub, $start, $fin, $path, $file, $exit, $host, $params) = @$ent;
    my $res = $dbh->do(qq(INSERT INTO Task (owner, state_code, application_id, submit_time, start_time,
					    finish_time, output_path, output_file, params) VALUES
			  (?,?,?,?,?,?,?,?,?)), undef,
		       $owner, $state, $app, $sub, $start, $fin, $path, $file, $params);
    if ($res ne 1)
    {
	die "bad insert\n";
    }
    my $id = $dbh->last_insert_id(undef, undef, 'Task', 'id');
    $sth->execute($cj);
    my $cjid = $sth->fetchrow;
    $cjid or die;
    print "id=$id $cj $cjid\n";
    $isth->execute($id, $cjid);
    $dbh->commit;
}
