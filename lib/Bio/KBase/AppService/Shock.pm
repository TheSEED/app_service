package Bio::KBase::AppService::Shock;

use strict;
use REST::Client;
use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;
use HTTP::Request::Common;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(ua server rest json auth_token));

sub new
{
    my($class, $server, $auth_token) = @_;

    my $ua = LWP::UserAgent->new();
    my $rest = REST::Client->new(useragent => $ua);
    my @auth_header;
    if ($auth_token)
    {
	@auth_header = (Authorization => "OAuth $auth_token");
	$rest->addHeader(@auth_header);
    }

    my $self = {
	server => $server,
	ua => $ua,
	rest => $rest,
	json => JSON::XS->new,
	(defined($auth_token) ? (auth_token => $auth_token) : ()),
	auth_header => \@auth_header,
	tags => {},
    };
    return bless $self, $class;
}

sub tag_nodes
{
    my($self, %tags) = @_;
    
    $self->{tags}->{$_} = $tags{$_} foreach keys %tags;
}

sub get_file
{
    my($self, $node) = @_;

    my $res = $self->rest->GET($self->server . "/node/$node?download");
    if ($self->rest->responseCode != 200)
    {
	die "get_file failed: " . $self->rest->responseContent();
    }
    return $self->rest->responseContent();
}

sub get_node
{
    my($self, $node) = @_;

    if ($node !~ /^http/)
    {
	$node = $self->server . "/node/$node";
    }
    my $res = $self->rest->GET($node);
    if ($self->rest->responseCode != 200)
    {
	die "get_node failed: " . $self->rest->responseContent();
    }
    my $obj = $self->json->decode($self->rest->responseContent());
    return $obj->{data};
}

sub put_file
{
    my($self, $file) = @_;
    my $url = $self->server . "/node";
    my $res = $self->ua->post($url,
			      Content_Type => 'multipart/form-data',
			      Content => [upload => [$file]]);
    if ($res->is_success)
    {
	my $ret = $self->json->decode($res->content);
	my $id = $ret->{data}->{id};

	$self->put_attributes($id);
	return $id;
    }
    else
    {
	die "put_file failed: " . $res->content;
    }
}    
	    
sub put_file_data
{
    my($self, $file_data, $name) = @_;
    $name = "user_data" unless $name;
    my $url = $self->server . "/node";
    my $res = $self->ua->post($url,
			      @{$self->{auth_header}},
			      Content_Type => 'multipart/form-data',
			      Content_Length => length($file_data),
			      Content => [upload => [undef, $name, Content => $file_data]]);
    if ($res->is_success)
    {
	my $ret = $self->json->decode($res->content);
	my $id = $ret->{data}->{id};
	$self->put_attributes($id);
	# print STDERR Dumper($ret);
	return $id;
    }
    else
    {
	die "put_file_data failed: " . $res->content;
    }
}    
	    

sub put_attributes
{
    my($self, $node) = @_;

    return unless %{$self->{tags}};

    my $tjson = $self->json->encode($self->{tags});
    my $url = $self->server . "/node/$node";
    my $req = HTTP::Request::Common::POST($url, 
					  @{$self->{auth_header}},
					  Content_Type => 'multipart/form-data',
					  Content => [attributes_str => $tjson]);
    $req->method('PUT');
    print STDERR Dumper($req);
    my $res = $self->ua->request($req);
    print STDERR Dumper($res->content);
}


1;
