use Bio::KBase::AppService::AppServiceImpl;

use Bio::KBase::AppService::Monitor;
use Bio::KBase::AppService::Quick;
use Bio::KBase::AppService::Service;

use Plack::Middleware::CrossOrigin;
use Plack::Builder;
use Data::Dumper;

our $have_jira;
eval {
    require Bio::BVBRC::JiraSubmission::JiraSubmissionImpl;
    require Bio::BVBRC::JiraSubmission::Service;
    $have_jira = 1;
};

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

my $jira_rpc_handler;
if ($have_jira)
{
    my @jira_dispatch;

    my $obj = Bio::BVBRC::JiraSubmission::JiraSubmissionImpl->new;
    push(@jira_dispatch, 'JiraSubmission' => $obj);

    my $jira_server = Bio::BVBRC::JiraSubmission::Service->new(instance_dispatch => { @jira_dispatch },
							       allow_get => 0,				     
							      );	     
    $jira_rpc_handler = sub { $jira_server->handle_input(@_) };
}

$handler = builder {
    mount "/ping" => sub { $server->ping(@_); };
    mount "/auth_ping" => sub { $server->auth_ping(@_); };
    mount "/task_info" => sub { $obj->_task_info(@_); };
    mount "/monitor" => Bio::KBase::AppService::Monitor->psgi_app;
    mount "/quick" => Bio::KBase::AppService::Quick->psgi_app;
    mount "/jira" => $jira_rpc_handler if $jira_rpc_handler;
    mount "/" => $rpc_handler;
};

$handler = Plack::Middleware::CrossOrigin->wrap( $handler, origins => "*", headers => "*", max_age => 86400);
