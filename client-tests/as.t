use Test::More;
use Config::Simple;
use JSON;
use Data::Dumper;

if (defined $ENV{KB_DEPLOYMENT_CONFIG} && -e $ENV{KB_DEPLOYMENT_CONFIG}) {
    $cfg = new Config::Simple($ENV{KB_DEPLOYMENT_CONFIG}) or
	die "can not create Config object";
    print "using $ENV{KB_DEPLOYMENT_CONFIG} for configs\n";
}
else {
    $cfg = new Config::Simple(syntax=>'ini');
    $cfg->param('app_service.service-host', '127.0.0.1');
    $cfg->param('app_service.service-port', '7109');
}

my $url = "http://" . $cfg->param('handle_service.service-host') . 
	  ":" . $cfg->param('handle_service.service-port');


# TODO for a pure client side test, remove AWE, Shock, and AppServiceImpl
BEGIN {
	use_ok( Bio::KBase::AppService::Client );
	use_ok( Bio::KBase::AppService::Awe );
	use_ok( Bio::KBase::AppService::Shock );
	use_ok( Bio::KBase::AppService::AppServiceImpl );
}

can_ok("Bio::KBase::AppService::Client", qw(
    enumerate_apps
    start_app
    query_task_status
    enumerate_tasks
   )
);
