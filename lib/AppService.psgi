use Bio::KBase::AppService::AppServiceImpl;

use Bio::KBase::AppService::Monitor;
use Bio::KBase::AppService::Quick;
use Bio::KBase::AppService::Service;
use Plack::Middleware::CrossOrigin;
use Plack::Builder;
use Data::Dumper;

my @dispatch;

my $obj = Bio::KBase::AppService::AppServiceImpl->new;
push(@dispatch, 'AppService' => $obj);
Bio::KBase::AppService::Monitor::set_impl($obj);
Bio::KBase::AppService::Quick::set_impl($obj);

my $server = Bio::KBase::AppService::Service->new(instance_dispatch => { @dispatch },
				allow_get => 0,
			       );

my $rpc_handler = sub {
#    print STDERR Dumper(@_);
    $server->handle_input(@_);
};

$handler = builder {
    mount "/ping" => sub { $server->ping(@_); };
    mount "/auth_ping" => sub { $server->auth_ping(@_); };
    mount "/task_info" => sub { $obj->_task_info(@_); };
    mount "/monitor" => Bio::KBase::AppService::Monitor->psgi_app;
    mount "/quick" => Bio::KBase::AppService::Quick->psgi_app;
    mount "/" => $rpc_handler;
};

$handler = Plack::Middleware::CrossOrigin->wrap( $handler, origins => "*", headers => "*", max_age => 86400);
