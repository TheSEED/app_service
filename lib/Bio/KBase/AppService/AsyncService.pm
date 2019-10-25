package Bio::KBase::AppService::AsyncService;

# See http://xmlrpc-epi.sourceforge.net/specs/rfc.fault_codes.php for error codes

use strict;
use Data::Dumper;
use Moose;
use POSIX;
use JSON::XS;
use Class::Load qw();
use Config::Simple;
my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday(); };
};

use P3AuthToken;
use P3TokenValidator;

has 'impl' => (is => 'ro', isa => 'Bio::KBase::AppService::AppServiceImpl');
has 'valid_methods' => (is => 'ro', isa => 'HashRef', lazy => 1,
			builder => '_build_valid_methods');
has 'validator' => (is => 'ro', isa => 'P3TokenValidator', lazy => 1, builder => '_build_validator');
has 'json' => (is =>'ro', isa => 'JSON::XS', lazy => 1, default => sub { JSON::XS->new->pretty(1); });

our $CallContext;

our %return_counts = (
        'service_status' => 1,
        'enumerate_apps' => 1,
        'start_app' => 1,
        'start_app2' => 1,
        'query_tasks' => 1,
        'query_task_summary' => 1,
        'query_app_summary' => 1,
        'query_task_details' => 1,
        'enumerate_tasks' => 1,
        'enumerate_tasks_filtered' => 2,
        'kill_task' => 2,
        'kill_tasks' => 1,
        'rerun_task' => 1,
        'version' => 1,
);

our %method_authentication = (
        'service_status' => 'required',
        'enumerate_apps' => 'required',
        'start_app' => 'required',
        'start_app2' => 'required',
        'query_tasks' => 'required',
        'query_task_summary' => 'required',
        'query_app_summary' => 'required',
        'query_task_details' => 'required',
        'enumerate_tasks' => 'required',
        'enumerate_tasks_filtered' => 'required',
        'kill_task' => 'required',
        'kill_tasks' => 'required',
        'rerun_task' => 'required',
);

sub _build_validator
{
    my($self) = @_;
    return P3TokenValidator->new();

}


sub _build_valid_methods
{
    my($self) = @_;
    my $methods = {
        'service_status' => 1,
        'enumerate_apps' => 1,
        'start_app' => 1,
        'start_app2' => 1,
        'query_tasks' => 1,
        'query_task_summary' => 1,
        'query_app_summary' => 1,
        'query_task_details' => 1,
        'enumerate_tasks' => 1,
        'enumerate_tasks_filtered' => 1,
        'kill_task' => 1,
        'kill_tasks' => 1,
        'rerun_task' => 1,
        'version' => 1,
    };
    return $methods;
}

=item B<handle_rpc>

JSONRPC handler method.

=cut
    
sub handle_rpc
{
    my($self, $env) = @_;

    # print STDERR Dumper($env);
    my $req = Plack::Request->new($env);

    my $body = $req->content();

    my $body_dat = eval { $self->json->decode($body); };
    if ($@)
    {
	return $self->error_return($req, { code => -32700, message => 'JSON parse failed' });
    }

    my($id, $full_method, $params) = @$body_dat{qw(id method params)};

    my($svc, $method) = split(/\./, $full_method, 2);

    if (ref($params) ne 'ARRAY')
    {
	return $self->error_return($req, { code => -32700, message => 'Invalid parameters' }, $id);
    }
	
    if ($svc ne "AppService" || !$self->valid_methods->{$method})
    {
	return $self->error_return($req, { code => -32601, message => 'Method not found' }, $id);
    }

    return $self->call_method($req, $id, $method, $params);
}

sub error_return
{
    my($self, $req, $error_obj, $id) = @_;

    warn "Returning error: " . Dumper($error_obj);
    return [500, ['Content-Type' => 'application/json'], [$self->json->encode({ jsonrpc => '2.0', id => $id, error => $error_obj})]];
}

sub trim {
    my ($str) = @_;
    if (!(defined $str)) {
        return $str;
    }
    $str =~ s/^\s+|\s+$//g;
    return $str;
}

sub getIPAddress {
    my ($self, $req) = @_;
    my $xFF = trim($req->header("X-Forwarded-For"));
    my $realIP = trim($req->header("X-Real-IP"));
    # my $nh = $self->config->{"dont_trust_x_ip_headers"};
    my $nh;
    my $trustXHeaders = !(defined $nh) || $nh ne "true";

    if ($trustXHeaders) {
        if ($xFF) {
            my @tmp = split(",", $xFF);
            return trim($tmp[0]);
        }
        if ($realIP) {
            return $realIP;
        }
    }
    return $req->address;
}

#
# Ping method reflected from /ping on the service.
#
sub ping
{
    my($self, $env) = @_;
    return [ 200, ["Content-type" => "text/plain"], [ "OK\n" ] ];
}


#
# Authenticated ping method reflected from /auth_ping on the service.
#
sub auth_ping
{
    my($self, $env) = @_;

    my $req = Plack::Request->new($env);
    my $token = $req->header("Authorization");

    if (!$token)
    {
	return [401, [], ["Authentication required"]];
    }

    my $auth_token = P3AuthToken->new(token => $token, ignore_authrc => 1);
    my($valid, $validate_err) = $self->validator->validate($auth_token);

    if ($valid)
    {
	return [200, ["Content-type" => "text/plain"], ["OK " . $auth_token->user_id . "\n"]];
    }
    else
    {
        warn "Token validation error $validate_err\n";
	return [403, [], ["Authentication failed"]];
    }
}

sub call_method {
    my ($self, $req, $id, $method, $params) = @_;

    my $ctx = Bio::KBase::AppService::ServiceContext->new(client_ip => $self->getIPAddress($req));
    $ctx->module('AppService');
    $ctx->method($method);
    $ctx->call_id($self->{_last_call}->{id});
    
    do {
	# Service AppService requires authentication.
	
	my $method_auth = $method_authentication{$method};
	$ctx->authenticated(0);
	if ($method_auth eq 'none')
	{
	    # No authentication required here. Move along.
	}
	else
	{
	    my $token = $req->header("Authorization");
	    
	    if (!$token && $method_auth eq 'required')
	    {
		return $self->error_return($req, { code => -32603, message => "Authentication required for AppService but no authentication header was passed", id => $id });
	    }
	    
	    my $auth_token = P3AuthToken->new(token => $token, ignore_authrc => 1);
	    my($valid, $validate_err) = $self->validator->validate($auth_token);
	    # Only throw an exception if authentication was required and it fails
	    if ($method_auth eq 'required' && !$valid)
	    {
		return $self->error_return($req, { code => -32603, message => "Token validation failed: $validate_err", id => $id });
	    } elsif ($valid) {
		$ctx->authenticated(1);
		$ctx->user_id($auth_token->user_id);
		$ctx->token( $token);
	    }
	}
    };
    local $CallContext = $ctx;
    local $Bio::KBase::AppService::Service::CallContext = $ctx;
    # print STDERR Dumper($ctx);
    my @result;
    do {
	# 
	# Process tag and metadata information if present.
	#
	my $tag = $req->header("Kbrpc-Tag");
	if (!$tag)
	{
	    if (!$self->{hostname}) {
		chomp($self->{hostname} = `hostname`);
                $self->{hostname} ||= 'unknown-host';
	    }

	    my ($t, $us) = &$get_time();
	    $us = sprintf("%06d", $us);
	    my $ts = strftime("%Y-%m-%dT%H:%M:%S.${us}Z", gmtime $t);
	    $tag = "S:$self->{hostname}:$$:$ts";
	}
	local $ENV{KBRPC_TAG} = $tag;
	my $kb_metadata = $req->header("Kbrpc-Metadata");
	my $kb_errordest = $req->header("Kbrpc-Errordest");
	local $ENV{KBRPC_METADATA} = $kb_metadata if $kb_metadata;
	local $ENV{KBRPC_ERROR_DEST} = $kb_errordest if $kb_errordest;

	my $stderr = Bio::KBase::AppService::ServiceStderrWrapper->new($ctx, $get_time);
	$ctx->stderr($stderr);

        my $xFF = $req->header("X-Forwarded-For");
	
        my $err;
        eval {
	    local $SIG{__WARN__} = sub {
		my($msg) = @_;
		print STDERR $msg;
	    };

            @result = $self->impl->$method(@$params);
        };
	
        if ($@)
        {
            my $err = $@;
	    print STDERR "Call error: $@";
	    $stderr->log($err);
	    $ctx->stderr(undef);
	    undef $stderr;
            my $nicerr;
	    my $str = "$err";
	    my $msg = $str;
	    $msg =~ s/ at [^\s]+.pm line \d+.\n$//;
	    $nicerr =  {code => -32603, # perl error from RPC::Any::Exception
                            message => $msg,
                            data => $str,
                            context => $ctx,
			    id => $id
                            };
            return $self->error_return($req, $nicerr);
        }
	$ctx->stderr(undef);
	undef $stderr;
    };

    if (@result == 1 && ref($result[0]) eq 'CODE')
    {
	#
	# Delayed result.
	return sub {
	    my $responder = shift;

	    #
	    # $responder is what is to be invoked with the output from the call.
	    # We want the RPC implementation to be given a sub to call
	    # with the results list, so we construct that sub here.
	    #
	    my $rpc_cb = $result[0];
	    my $handle_resp = sub {
		my($res) = @_;
		#
		# Result is a list if it is valid; it is a hash with a message field if an error
		#
		if (ref($res) eq 'ARRAY')
		{
		    my @result = @$res;
		    my $result;
		    if ($return_counts{$method} == 1)
		    {
			$result = [$result[0]];
		    }
		    else
		    {
			$result = \@result;
		    }
		    $responder->([200, ['Content-Type' => 'application.json'], [$self->json->encode({jsonrpc => '2.0', result => $result, id => $id})]]);
		}
		elsif (ref($res) eq 'HASH')
		{
		    $res->{code} = -32603;
		    $res->{message} //= "method failure";
		    $responder->([500, ['Content-Type' => 'application.json'], [$self->json->encode({ jsonrpc => '2.0', error => $res, id => $id})]]);
		}
	    };
	    $rpc_cb->($handle_resp);
	}
    }
    my $result;
    if ($return_counts{$method} == 1)
    {
        $result = [$result[0]];
    }
    else
    {
        $result = \@result;
    }
    return [200, ['Content-Type' => 'application.json'], [$self->json->encode({jsonrpc => '2.0', result => $result, id => $id})]];
}


sub get_method
{
    my ($self, $data) = @_;
    
    my $full_name = $data->{method};
    
    $full_name =~ /^(\S+)\.([^\.]+)$/;
    my ($package, $method) = ($1, $2);
    
    if (!$package || !$method) {
	$self->exception('NoSuchMethod',
			 "'$full_name' is not a valid method. It must"
			 . " contain a package name, followed by a period,"
			 . " followed by a method name.");
    }

    if (!$self->valid_methods->{$method})
    {
	$self->exception('NoSuchMethod',
			 "'$method' is not a valid method in service AppService.");
    }
	
    my $inst = $self->instance_dispatch->{$package};
    my $module;
    if ($inst)
    {
	$module = $inst;
    }
    else
    {
	$module = $self->get_module($package);
	if (!$module) {
	    $self->exception('NoSuchMethod',
			     "There is no method package named '$package'.");
	}
	
	Class::Load::load_class($module);
    }
    
    if (!$module->can($method)) {
	$self->exception('NoSuchMethod',
			 "There is no method named '$method' in the"
			 . " '$package' package.");
    }
    
    return { module => $module, method => $method, modname => $package };
}

package Bio::KBase::AppService::ServiceContext;

use strict;

=head1 NAME

Bio::KBase::AppService::ServiceContext

head1 DESCRIPTION

A KB RPC context contains information about the invoker of this
service. If it is an authenticated service the authenticated user
record is available via $context->user. The client IP address
is available via $context->client_ip.

=cut

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(user_id client_ip authenticated token
                             module method call_id hostname stderr));

sub new
{
    my($class, @opts) = @_;

    if (!defined($opts[0]) || ref($opts[0]))
    {
        # We were invoked by old code that stuffed a logger in here.
	# Strip that option.
	shift @opts;
    }
    
    my $self = {
        @opts,
    };
    chomp($self->{hostname} = `hostname`);
    $self->{hostname} ||= 'unknown-host';
    return bless $self, $class;
}

package Bio::KBase::AppService::ServiceStderrWrapper;

use strict;
use POSIX;
use Time::HiRes 'gettimeofday';

sub new
{
    my($class, $ctx, $get_time) = @_;
    my $self = {
	get_time => $get_time,
    };
    my $dest = $ENV{KBRPC_ERROR_DEST} if exists $ENV{KBRPC_ERROR_DEST};
    my $tag = $ENV{KBRPC_TAG} if exists $ENV{KBRPC_TAG};
    my ($t, $us) = gettimeofday();
    $us = sprintf("%06d", $us);
    my $ts = strftime("%Y-%m-%dT%H:%M:%S.${us}Z", gmtime $t);

    my $name = join(".", $ctx->module, $ctx->method, $ctx->hostname, $ts);

    if ($dest && $dest =~ m,^/,)
    {
	#
	# File destination
	#
	my $fh;

	if ($tag)
	{
	    $tag =~ s,/,_,g;
	    $dest = "$dest/$tag";
	    if (! -d $dest)
	    {
		mkdir($dest);
	    }
	}
	if (open($fh, ">", "$dest/$name"))
	{
	    $self->{file} = "$dest/$name";
	    $self->{dest} = $fh;
	}
	else
	{
	    warn "Cannot open log file $dest/$name: $!";
	}
    }
    else
    {
	#
	# Log to string.
	#
	my $stderr;
	$self->{dest} = \$stderr;
    }
    
    bless $self, $class;

    for my $e (sort { $a cmp $b } keys %ENV)
    {
	$self->log_cmd($e, $ENV{$e});
    }
    return $self;
}

sub redirect
{
    my($self) = @_;
    if ($self->{dest})
    {
	return("2>", $self->{dest});
    }
    else
    {
	return ();
    }
}

sub redirect_both
{
    my($self) = @_;
    if ($self->{dest})
    {
	return(">&", $self->{dest});
    }
    else
    {
	return ();
    }
}

sub timestamp
{
    my($self) = @_;
    my ($t, $us) = $self->{get_time}->();
    $us = sprintf("%06d", $us);
    my $ts = strftime("%Y-%m-%dT%H:%M:%S.${us}Z", gmtime $t);
    return $ts;
}

sub log
{
    my($self, $str) = @_;
    my $d = $self->{dest};
    my $ts = $self->timestamp();
    if (ref($d) eq 'SCALAR')
    {
	$$d .= "[$ts] " . $str . "\n";
	return 1;
    }
    elsif ($d)
    {
	print $d "[$ts] " . $str . "\n";
	return 1;
    }
    return 0;
}

sub log_cmd
{
    my($self, @cmd) = @_;
    my $d = $self->{dest};
    my $str;
    my $ts = $self->timestamp();
    if (ref($cmd[0]))
    {
	$str = join(" ", @{$cmd[0]});
    }
    else
    {
	$str = join(" ", @cmd);
    }
    if (ref($d) eq 'SCALAR')
    {
	$$d .= "[$ts] " . $str . "\n";
    }
    elsif ($d)
    {
	print $d "[$ts] " . $str . "\n";
    }
	 
}

sub dest
{
    my($self) = @_;
    return $self->{dest};
}

sub text_value
{
    my($self) = @_;
    if (ref($self->{dest}) eq 'SCALAR')
    {
	my $r = $self->{dest};
	return $$r;
    }
    else
    {
	return $self->{file};
    }
}


1;
