=head1 NAME
    
    p3x-qstat - show the PATRIC application service queue
    
=head1 SYNOPSIS

    p3x-qstat [OPTION]...
    
=head1 DESCRIPTION

Queries the PATRIC application service queue.

=cut

use strict;
use Data::Dumper;
use JSON::XS;
use Bio::KBase::AppService::Schema;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_user sched_db_pass sched_db_name);
use DateTime::Format::Duration;

use Text::Table;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["application|A=s" => "Limit results to the given application"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV > 0;

my $schema = Bio::KBase::AppService::Schema->connect("dbi:mysql:" . sched_db_name . ";host=" . sched_db_host,
						     sched_db_user, sched_db_pass);
$schema or die "Cannot connect to database: " . Bio::KBase::AppService::Schema->errstr;

#
# Basic query is to enumerate all queued and running jobs.
#

my @app_condition = (application_id => $opt->application) if $opt->application;

my $sort = {-desc => 'submit_time'};
my $tasks = $schema->resultset('Task')->search(
					   {
					       state_code => { -in => ['Q','S', 'R', 'C', 'F'] },
					       owner => { -like => '%olson%' },
					       @app_condition,
					       'task_executions.active' => [undef, 1],
					   },
					   {
#					       distinct => 1,
					       limit => 20,
#					       columns => ['task_executions.active', 'task_executions.task_id', 'task_executions.cluster_job_id', 'me.id', 'me.owner' ],
					       join => {'task_executions' => 'cluster_job' },
#					       prefetch => ['owner', 'state_code'],
					       prefetch => ['owner', 'state_code', { 'task_executions' => 'cluster_job' } ],
					       order_by => [$sort, 'me.id'],
					   }
						 );

my @cols;
push(@cols,
 { title => "Job ID" },
 { title => "State" },
 { title => "Owner" },
 { title => "Application" },
 { title => "Elapsed" },
 { title => "Cluster" },
 { title => "Cluster\njob" },
 { title => "Cluster\njob status "},
 { title => "Nodes" },
 { title => "Memory\nused" },
     );

my $tbl = Text::Table->new(@cols);

my $elap_fmt = DateTime::Format::Duration->new(pattern => '%T', normalize => 1);

while (my $task = $tasks->next())
{
    my $tf = $task->task_executions->first();
    my $cj;
    if ($tf)
    {
	$cj = $tf->cluster_job;
    }
    (my $owner = $task->owner) =~ s/\@patricbrc.org$//;
    my $elap = $task->finish_time ? $task->finish_time->subtract_datetime($task->start_time) : "";
    $tbl->add($task->id, $task->state_code, $owner, $task->application_id,
	      ($elap ? $elap_fmt->format_duration($elap) : ""),
	      $cj ? ($cj->cluster_id, $cj->job_id, $cj->job_status, $cj->nodelist, $cj->maxrss) : ());
}

print $tbl;

