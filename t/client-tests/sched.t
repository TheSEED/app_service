use Data::Dumper;
use Test::Exception;
use Test::More;
use strict;
use 5.010;

use_ok('P3AuthToken');
use_ok('Bio::KBase::AppService::AppSpecs');
use_ok('Bio::KBase::AppService::Scheduler');
use_ok('Bio::KBase::AppService::SlurmCluster');

my $dir = shift;

my $token = new_ok('P3AuthToken');

my $specs = new_ok('Bio::KBase::AppService::AppSpecs', [$dir]);

my $sched = new_ok('Bio::KBase::AppService::Scheduler', [specs => $specs]);

my $cluster = new_ok('Bio::KBase::AppService::SlurmCluster', ['Bebop',
							      schema => $sched->schema,
							      resources => ["-p bdws",
									    "-N 1",
									    "--ntasks-per-node 1",
									    "--time 1:00:00"],
							      ]);
#my $cluster = new_ok('Bio::KBase::AppService::SlurmCluster', ['TSlurm', schema => $sched->schema]);

$sched->default_cluster($cluster);

my $code = $sched->schema->resultset('TaskState')->find({description => 'Submitted to cluster'});
ok($code);
say $code->id;
#
# Test app lookup/creation
#

my $res = $sched->find_app("Sleep");
isa_ok($res, 'Bio::KBase::AppService::Schema::Result::Application');
say "res=" . $res->id . " " . ref($res);;

dies_ok { $sched->find_app("Sleepx") };

my $monitor_url = "https://p3.theseed.org/services/app_service/task_info";
my $task = $sched->start_app($token, "Sleep", $monitor_url, { sleep_time => 10 }, {});
my $dtask = $sched->start_app($token, "Date", $monitor_url, { output_path => '/olson@patricbrc.org/home/test', output_file => 'd1' }, {});

$sched->start_timers();

use AnyEvent;
my $cv = AnyEvent->condvar;
$cv->recv;

done_testing;
