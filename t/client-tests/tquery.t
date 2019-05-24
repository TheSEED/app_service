use strict;

use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::Scheduler;
use Bio::KBase::AppService::AppServiceImpl;
use Data::Dumper;
$Data::Dumper::Maxdepth = 3;


my $obj = Bio::KBase::AppService::AppServiceImpl->new;
my $specs = Bio::KBase::AppService::AppSpecs->new($obj->{app_dir});

my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);

#my $tasks = $sched->query_tasks('olson@patricbrc.org', [22581,22573,1000]);
#print Dumper($tasks);
#my $summary = $sched->query_task_summary('olson@patricbrc.org');
#print Dumper($summary);

my $page = 10;
for my $i (0..3)
{
    my $tasks = $sched->enumerate_tasks('olson@patricbrc.org', $i * $page, $page);
    print Dumper($tasks);
}
