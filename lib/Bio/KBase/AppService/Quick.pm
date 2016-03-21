package Bio::KBase::AppService::Quick;

#
# Quick interface to the app service.
#

use Dancer2;
use strict;
use Data::Dumper;
use POSIX;
use LWP::UserAgent;
use HTTP::Headers;
use JSON::XS;
use MIME::Base64;
use Bio::KBase::AppService::Awe;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::Client;

our $impl;
our $json = JSON::XS->new->pretty;
our %token_cache;

set session => 'YAML';
set views => path(dirname(__FILE__), 'templates');
set layout => undef;
set template => 'template_toolkit';
set engines => {
    template => {
	template_toolkit => {
	},
    },
};
set content_type => 'text/plain';
set error_template => undef;

sub set_impl
{
    my($i) = @_;
    $impl = $i;
}

hook before => sub {
    my $user = param('username');
    my $pass = param('password');

    if (!$user)
    {
	#
	# Try basic auth header
	#

	my $h = request->env->{HTTP_AUTHORIZATION};
	if ($h =~ /^Basic\s+(.*)$/)
	{
	    my $d = decode_base64($1);
	    if ($d =~ /^(.*):(.*)$/)
	    {
		$user = $1;
		$pass = $2;
	    }
	}
		
    }

    return unless ($user && $pass);

    my $token_obj = $token_cache{$user, $pass};

    if (!$token_obj)
    {
	my $ua = LWP::UserAgent->new;
	
	if ($user =~ /^([^@]+)\@patricbrc.org$/)
	{
	    my $url = "https://user.patricbrc.org/authenticate";
	    my $content = { username => $1, password => $pass };
	    
	    my $res = $ua->post($url,$content);
	    if ($res->is_success)
	    {
		my $txt = $res->content;
		$token_obj = { access_token => $txt, user_name => $user };
	    }
	}
	else
	{
	    my $headers = HTTP::Headers->new;
	    my %headers;
	    $headers->authorization_basic($user, $pass);
	    $headers{Authorization} = $headers->header('Authorization');
	    my $res = $ua->get("http://rast.nmpdr.org/goauth/token?grant_type=client_credentials",
			       %headers);
	    if ($res->is_success)
	    {
		$token_obj = decode_json($res->content);
		$token_cache{$user, $pass} = $token_obj;
		
	    }
	    else
	    {
		warn "Could not retrieve token for user $user\n";
	    }
	}
    }
    
    if ($token_obj)
    {
	var token => $token_obj->{access_token};
	var user => $token_obj->{user_name};
	$ENV{KB_AUTH_TOKEN} = $token_obj->{access_token};
    }
    else
    {
	delete $ENV{KB_AUTH_TOKEN};
    }
	
};

post '/submit/GenomeAnnotation' => sub {
    my($app) = @_;
    my $token = vars->{token};

    my $p = params();

    if (!$token)
    {
	send_error("Authentication required", 403);
    }

    #
    # The quick interface defaults to inputs in a folder "QuickData" 
    #

    my $base = strftime("base-%Y-%m-%d-%H-%M-%S", localtime time);
    
    my $path = params->{path};
    if (!$path)
    {
	$path = "/" . vars->{user} . "/home/QuickData/$base";
    }

    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();
    print Dumper($ws);

    eval {
	my $res = $ws->get({ objects => [$path], metadata_only => 1 });
	Dumper("exists ", $res);
    };
    if ($@)
    {
	my $res = $ws->create({ objects => [ [$path, 'folder' ] ] });
	print Dumper($res);
    }

    my $cpath = "$path/contigs";

    $ws->save_data_to_file(request->body, undef, $cpath, "contigs", 0, 1, $token);

    my $name = params->{scientific_name} || "Unknown sp.";
    my $tax = params->{taxonomy_id} || 6666666;
    my $code = params->{genetic_code} || 11;
    my $domain = params->{domain} || 'B';
    my $params = {
	contigs => $cpath,
	scientific_name => $name,
	taxonomy_id => $tax,
	code => $code,
	domain => $domain,
	output_path => $path,
	output_file => "genome",
    };
    my $appserv = Bio::KBase::AppService::Client->new();
    my $res = $appserv->start_app('GenomeAnnotation', $params, $path);

    return $res->{id};
};

get '/:id/status' => sub {
    my($app) = @_;

    my $token = vars->{token};
    if (!$token)
    {
	send_error("Authentication required", 403);
    }

    my $id = params->{id};

    my $appserv = Bio::KBase::AppService::Client->new();
    my $details = $appserv->query_tasks([$id]);

    if (!($details && exists($details->{$id})))
    {
	send_error("ID not found", 404);
    }
    $details = $details->{$id};

    my $status = $details->{status};

    return $status;
};

get '/:id/retrieve' => sub {
    my($app) = @_;

    my $token = vars->{token};
    if (!$token)
    {
	send_error("Authentication required", 403);
    }

    my $id = params->{id};

    my $appserv = Bio::KBase::AppService::Client->new();
    my $details = $appserv->query_tasks([$id]);

    if (!($details && exists($details->{$id})))
    {
	send_error("ID not found", 404);
    }
    $details = $details->{$id};

    my $status = $details->{status};

    if ($status ne 'completed')
    {
	send_error("results not ready", 404);
    }

    my $params = $details->{parameters};
    my $path = $params->{output_path} . "/." . $params->{output_file} . "/" .  $params->{output_file} . ".genome";
    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();

    my $out;
    eval {
	my $res = $ws->get( { objects => [$path] });
	my $ent = $res->[0];
	my($meta, $data) = @$ent;
	bless $meta, 'Bio::P3::Workspace::ObjectMeta';

	if ($meta->shock_url)
	{
	    print "GET " . $meta->shock_url . "\n";
	    my $ua = LWP::UserAgent->new;
	    my $wres = $ua->get($meta->shock_url . "?download",
				Authorization => "OAuth " . $token);
	    $out = $wres->content;
	}
	else
	{
	    $out = $data;
	}
    };

    if ($@)
    {
	send_error("error retrieving results from $path", 500);
    }
    else
    {
	return $out;
    }
};


1;
    
