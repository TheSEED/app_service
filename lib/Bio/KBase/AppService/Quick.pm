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
use JSON::XS qw//;
use MIME::Base64;
use File::Spec;
use Bio::KBase::AppService::Awe;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::Client;
use P3AuthToken;
use P3TokenValidator;

our $impl;
our $json = JSON::XS->new->pretty;
our %token_cache;
our $validator = P3TokenValidator->new();

set views => path(dirname(__FILE__), 'templates');
set content_type => 'text/plain';
set error_template => undef;

print STDERR Dumper(Quick => config);

sub set_impl
{
    my($i) = @_;
    $impl = $i;
}

hook before => sub {
    my $user = param('username');
    my $pass = param('password');

    delete $ENV{KB_AUTH_TOKEN};
    var token => undef;
    var user => undef;

    my $token;

    if (!$user)
    {
	#
	# Do we have a basic authorization or the normal PATRIC service authentication
	# header ?
	#

	my $auth_hdr = request->header("Authorization");
	if (defined($auth_hdr))
	{
	    if ($auth_hdr =~ /^Basic\s+(.*)$/)
	    {
		my $d = decode_base64($1);
		if ($d =~ /^(.*):(.*)$/)
		{
		    $user = $1;
		    $pass = $2;
		}
	    }
	    else
	    {
		#
		# Treat as bearer token with optional OAuth in front.
		#

		$token = $auth_hdr;
		$token =~ s/^OAuth\s+//;
		my $auth_token = P3AuthToken->new(token => $token, ignore_authrc => 1);
		my($valid, $validate_err) = $validator->validate($auth_token);
		if (!$valid)
		{
		    warn "Invalid token $token received: $auth_token->{error_message}\n";
		    return;
		}
	    }
	}
    }

    if ($user && $pass)
    {
	$token = $token_cache{$user, $pass};
	
	if (!$token)
	{
	    my $ua = LWP::UserAgent->new;
	    
	    if ($user =~ /^([^@]+)\@patricbrc.org$/)
	    {
		my $url = "https://user.patricbrc.org/authenticate";
		my $content = { username => $1, password => $pass };
		
		my $res = $ua->post($url,$content);
		if ($res->is_success)
		{
		    $token = $res->content;
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
		    my $token_obj = JSON::XS::decode_json($res->content);
		    $token = $token_obj->{access_token};
		    $token_cache{$user, $pass} = $token;
		    
		}
		else
		{
		    warn "Could not retrieve token for user $user\n";
		}
	    }
	}
    }
    
    if ($token)
    {
	var token => $token;
	my($user) = $token =~ /\bun=([^|]+)/;
	var user => $user;
	$ENV{KB_AUTH_TOKEN} = $token;
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
    # print STDERR Dumper($ws);

    eval {
	my $res = $ws->get({ objects => [$path], metadata_only => 1 });
	# Dumper("exists ", $res);
    };
    if ($@)
    {
	my $res = $ws->create({ objects => [ [$path, 'folder' ] ] });
	# print STDERR Dumper($res);
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
	skip_indexing => (params->{skip_indexing} ? 1 : 0),
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
	    # print "GET " . $meta->shock_url . "\n";
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
    
