use strict;

use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::Scheduler;
use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::AppService::SlurmCluster;
use Data::Dumper;
#$Data::Dumper::Maxdepth = 3;



my $obj = Bio::KBase::AppService::AppServiceImpl->new;
my $specs = Bio::KBase::AppService::AppSpecs->new($obj->{app_dir});

my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);

my $cluster = Bio::KBase::AppService::SlurmCluster->new('P3Slurm',
							schema => $sched->schema);
$sched->default_cluster($cluster);

my $ret = $sched->kill_tasks('olson@patricbrc.org', [22676,22675, 100]);
print Dumper($ret);
exit;
my $tasks = $sched->query_tasks('olson@patricbrc.org', [22676]);
print Dumper(returned_tasks => $tasks);
exit;
#my $summary = $sched->query_task_summary('olson@patricbrc.org');
#print Dumper($summary);

my $page = 10000;
for my $i (0..0)
{
    my $tasks = $sched->enumerate_tasks('olson@patricbrc.org', $i * $page, $page);
    print Dumper($tasks->[0]);
}
