=head1 NAME
    
    p3x-qdel - delete a job
    
=head1 SYNOPSIS

    p3x-qdel [OPTION] jobid [jobid...]
    
=head1 DESCRIPTION

Deletes a job or jobs from the PATRIC application service.

=cut

use strict;
use Data::Dumper;
use JSON::XS;
use Bio::KBase::AppService::SchedulerDB;

use Text::Table;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV == 0;

my @task_ids;

foreach (@ARGV)
{
    /^\d+$/ or die "Invalid task id $_\n";
    push(@task_ids, $_);
}

my $db = Bio::KBase::AppService::SchedulerDB->new();

my $qs = join(", ", map { "?" } @task_ids);

#
# Mark queued jobs as terminated.
#
my $res = $db->dbh->do(qq(UPDATE Task
			  SET state_code = 'T'
			  WHERE state_code = 'Q' AND id IN ($qs)), undef, @task_ids);
print "Changed: $res\n";

#
# Running tasks
#


my $res = $db->dbh->selectall_arrayref(qq(SELECT t.id, t.state_code, cj.job_id, cj.job_status
					  FROM Task t LEFT OUTER JOIN TaskExecution te ON te.task_id = t.id
					  LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
					  WHERE t.state_code IN ('S', 'Q') AND t.id IN ($qs)), undef, @task_ids);

my @to_cancel = map { $_->[2] } @$res;
print "cancel: @to_cancel\n";
my $rc = system("scancel", @to_cancel);
if ($rc != 0)
{
    warn "scancel failed with rc=$rc\n";
}

__END__



my $tasks = $schema->resultset('Task')->search(
					   {
					       'me.id' => { -in => \@task_ids },
					   },
					   {
					       join => {'task_executions' => 'cluster_job' },
					       prefetch => ['owner', 'state_code', { 'task_executions' => 'cluster_job' } ],
					   }
						 );

my @cols;
push(@cols,
 { title => "Job ID" },
 { title => "State" },
 { title => "Owner" },
 { title => "Cluster job active" },
 { title => "Cluster" },
 { title => "Cluster job" },
 { title => "Cluster job status "},
     );

while (my $task = $tasks->next())
{
    my $te = $task->task_executions->first;

    #
    # If we have a task execution live, we will need to
    # try to cancel that. TODO
    #
    if ($te)
    {
    }
    $task->update({state_code => 'D'});
}
