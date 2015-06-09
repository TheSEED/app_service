use Bio::KBase::AppService::AppServiceImpl;

use Bio::KBase::AppService::Monitor;
use Bio::KBase::AppService::Service;
use Plack::Middleware::CrossOrigin;
use Plack::Builder;



my @dispatch;

my $obj = Bio::KBase::AppService::AppServiceImpl->new;
push(@dispatch, 'AppService' => $obj);
Bio::KBase::AppService::Monitor::set_impl($obj);

my $server = Bio::KBase::AppService::Service->new(instance_dispatch => { @dispatch },
				allow_get => 0,
			       );

my $rpc_handler = sub { $server->handle_input(@_) };

$handler = builder {
    mount "/ping" => sub { $server->ping(@_); };
    mount "/auth_ping" => sub { $server->auth_ping(@_); };
    mount "/task_info" => sub { $obj->_task_info(@_); };
    mount "/monitor" => Bio::KBase::AppService::Monitor->psgi_app;
    mount "/" => $rpc_handler;
};

$handler = Plack::Middleware::CrossOrigin->wrap( $handler, origins => "*", headers => "*");
