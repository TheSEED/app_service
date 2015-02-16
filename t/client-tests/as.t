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
    die "no KB_DEPLOYMENT_CONFIG found";
}

my $url = "http://" . $cfg->param('app_service.service-host') . 
	  ":" . $cfg->param('app_service.service-port');

ok(system("curl -h > /dev/null 2>&1") == 0, "curl is installed");
ok(system("curl $url > /dev/null 2>&1") == 0, "$url is reachable");

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
    query_tasks
    query_task_summary
    enumerate_tasks
   )
);


my ($obj, $apps, $task, $task_status, $task_summary);

isa_ok($obj = Bio::KBase::AppService::Client->new(), Bio::KBase::AppService::Client);
ok($apps = $obj->enumerate_apps(), "can call enumerate_apps()");
ok(ref $apps eq "ARRAY", "enumerate_apps() returns an array reference");

my $id = 'Date';
my $params = {};
my $workspace_id = '';

ok ($task = $obj->start_app($id, $params, $workspace_id),
    "can call start_app($id)");
ok ($task = $obj->query_tasks([$task->{id}]), "can call query_tasks");;
ok (ref $task eq "HASH", "query_tasks returns a hash ref");
ok ($task_summary = $obj->query_task_summary(), "can call query_task_summary");
ok (ref $task_summary eq "HASH", "task_summary is a hash ref");

undef $obj;
undef $apps;
undef $task;
undef $task_status;
undef $task_summary;


done_testing();
