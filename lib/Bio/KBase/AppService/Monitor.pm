package Bio::KBase::AppService::Monitor;

use Dancer2;
use strict;
use Data::Dumper;
use LWP::UserAgent;
use HTTP::Headers;
use JSON::XS;
use Bio::KBase::AppService::Awe;

our $impl;
our $json = JSON::XS->new->pretty;

set session => 'YAML';
set views => path(dirname(__FILE__), 'templates');
set layout => 'main';
set template => 'template_toolkit';
set engines => {
    template => {
	template_toolkit => {
	},
    },
};

sub set_impl
{
    my($i) = @_;
    $impl = $i;
}

hook before => sub {
    if (!session('user') && request->dispatch_path !~ m,^/login,) {
	forward '/monitor/login', { requested_path => request->dispatch_path };
    }
};

get '/' => sub {

    #
    # Here we enumerate all of the tasks, not just the user's.
    #

    my $count = 100;
    my $offset = 0;
    my $awe = Bio::KBase::AppService::Awe->new($impl->{awe_server}, session('token'));
    print Dumper($impl, session('token'));
    my $q = "/job?query&info.pipeline=AppService&limit=$count&offset=$offset";
    print STDERR "Query tasks: $q\n";
    my ($res, $error) = $awe->GET($q);
    my @jobs;
    if ($res)
    {
	for my $t (@{$res->{data}})
	{
	    my $d = {};
	    my $r = $impl->_awe_to_task($t);

	    $d->{id} = $t->{id};
	    $d->{user} = $t->{info}->{user};
	    $d->{started} = $t->{info}->{startedtime};
	    $d->{completed} = $t->{info}->{completedtime};
	    $d->{app} = $t->{info}->{userattr}->{app_id};
	    $d->{state} = $t->{state};

	    push @jobs, $d;
	    
	}
    }
    else
    {
	print "$error\n";
    }
    
    template 'index' => { title => "App service monitor",
			  jobs => \@jobs,
			  };
};

get '/task/:task_id' => sub {
    my $task_id = param('task_id');
    my $details = $impl->query_task_details($task_id);

    my $awe = Bio::KBase::AppService::Awe->new($impl->{awe_server}, session('token'));

    my($res, $error) = $awe->job($task_id);
    my %vars = (id => $task_id,
		details => $details,
		awe => $res,
		awe_txt => $json->encode($res),
		title => "Task $task_id",
		);
    template 'task', \%vars;
};

get '/login' => sub {
    template 'login', { title => "Log in", path => param('requested_path') };
};

get '/logout' => sub {
    app->destroy_session;
    redirect '/';
};

post '/login' => sub {
    my $ua = LWP::UserAgent->new;
    my $headers = HTTP::Headers->new;
    my %headers;
    $headers->authorization_basic(param('user'), param('password'));
    $headers{Authorization} = $headers->header('Authorization');
    my $res = $ua->get("http://rast.nmpdr.org/goauth/token?grant_type=client_credentials",
		       %headers);
    if ($res->is_success)
    {
	my $token = decode_json($res->content);
	session user => $token->{user_name};
	session token => $token->{access_token};
	redirect param('path') || '/';
    }
    else
    {
	redirect("/login?failed=1");
    }
};

1;
    
