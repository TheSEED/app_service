use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::AppService::Monitor;
use Bio::KBase::AppService::Quick;
use Bio::KBase::AppService::AsyncService;

use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::Scheduler;
use Bio::KBase::AppService::SlurmCluster;

#use Carp::Always;

use Plack::Middleware::CrossOrigin;
use Plack::Builder;
use Data::Dumper;

my @dispatch;

my $obj = Bio::KBase::AppService::AppServiceImpl->new;

my $specs = Bio::KBase::AppService::AppSpecs->new($obj->{app_dir});

my $sched = Bio::KBase::AppService::Scheduler->new(specs => $specs);


my $shared_cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
							schema => $sched->schema,
							resources => ["-p bdws",
								      "-N 1",
								      "--ntasks-per-node 1",
								      "--time 1:00:00"]);
my $cluster = Bio::KBase::AppService::SlurmCluster->new('Bebop',
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

$obj->{util}->scheduler($sched);
Bio::KBase::AppService::Monitor::set_impl($obj);
Bio::KBase::AppService::Quick::set_impl($obj);

my $server = Bio::KBase::AppService::AsyncService->new(impl => $obj);

my $rpc_handler = sub { $server->handle_rpc(@_); };

$handler = builder {
    mount "/ping" => sub { $server->ping(@_); };
    mount "/auth_ping" => sub { $server->auth_ping(@_); };
    mount "/task_info" => sub { $obj->_task_info(@_); };
    mount "/monitor" => Bio::KBase::AppService::Monitor->psgi_app;
    mount "/quick" => Bio::KBase::AppService::Quick->psgi_app;
    mount "/" => $rpc_handler;
};

$sched->start_timers();

$handler = Plack::Middleware::CrossOrigin->wrap( $handler, origins => "*", headers => "*");
