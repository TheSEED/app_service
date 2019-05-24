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
use Bio::KBase::AppService::Schema;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_user sched_db_pass sched_db_name);

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

my $schema = Bio::KBase::AppService::Schema->connect("dbi:mysql:" . sched_db_name . ";host=" . sched_db_host,
						     sched_db_user, sched_db_pass);
$schema or die "Cannot connect to database: " . Bio::KBase::AppService::Schema->errstr;

#
# Enumerate the requested jobs.
#

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
