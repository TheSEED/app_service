use Twiggy;

use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::AppService::Monitor;
use Bio::KBase::AppService::Quick;
use Bio::KBase::AppService::AsyncService;

use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::SlurmCluster;

# use Carp::Always;

use Plack::Middleware::CrossOrigin;
use Plack::Builder;
use Data::Dumper;
use Log::Dispatch;
use Log::Dispatch::File;

my @dispatch;

my $obj = Bio::KBase::AppService::AppServiceImpl->new;

my $logger;
if (my $f = $ENV{APP_SERVICE_STDERR})
{
    $logger = Log::Dispatch->new;
    $logger->add( Log::Dispatch::File->new(filename => $f, min_level => 'debug'));
}


my $specs = Bio::KBase::AppService::AppSpecs->new($obj->{app_dir});
print Dumper($specs);

Bio::KBase::AppService::Monitor::set_impl($obj);
Bio::KBase::AppService::Quick::set_impl($obj);

my $server = Bio::KBase::AppService::AsyncService->new(impl => $obj);

my $rpc_handler = sub { $server->handle_rpc(@_); };

print Dumper($logger);

$handler = builder {
    if ($logger)
    {
	enable 'LogDispatch', logger => $logger;
	enable 'LogStderr', no_tie => 1;
    }
    builder {
	mount "/ping" => sub { $server->ping(@_); };
	mount "/auth_ping" => sub { $server->auth_ping(@_); };
	mount "/task_info" => sub { $obj->_task_info(@_); };
	mount "/monitor" => Bio::KBase::AppService::Monitor->psgi_app;
	mount "/quick" => Bio::KBase::AppService::Quick->psgi_app;
	mount "/" => $rpc_handler;
    };
};

$handler = Plack::Middleware::CrossOrigin->wrap( $handler, origins => "*", headers => "*", max_age =>  86400);
