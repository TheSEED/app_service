use strict;
use Bio::KBase::AppService::Scheduler;
use Bio::KBase::AppService::SlurmCluster;
use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name
					 app_directory app_service_url);

use IPC::Run 'run';
use Try::Tiny;
use AnyEvent;

my $specs = Bio::KBase::AppService::AppSpecs->new(app_directory);
my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);
$sched->{task_start_disable} = 0;
$sched->load_apps();

my $cluster = Bio::KBase::AppService::SlurmCluster->new('P3Slurm',
							scheduler => $sched,
							schema => $sched->schema);

my $shared_cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
							scheduler => $sched,
							schema => $sched->schema,
							resources => ["-p bdws",
								      "-N 1",
								      "--ntasks-per-node 1",
								      "--time 1:00:00"]);
my $bebop_cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
							scheduler => $sched,
							schema => $sched->schema,
							resources => [
								      "-p bdwd",
								      "-x bdwd-0050",
								      # "-p bdwall",
								      "-N 1",
								      "-A PATRIC",
								      "--ntasks-per-node 1"],
							environment_config => ['module add jdk'], ['module add gnuplot']);





$sched->default_cluster($cluster);

$sched->start_timers();

my $run_cv = AnyEvent->condvar;
$run_cv->recv;
