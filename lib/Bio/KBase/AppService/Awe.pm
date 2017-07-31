package Bio::KBase::AppService::Awe;

use strict;
use REST::Client;
use LWP::UserAgent;
use JSON::XS;
use Data::Dumper;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(ua server rest json auth_token));

sub new
{
    my($class, $server, $auth_token) = @_;

    my $ua = LWP::UserAgent->new();
    my $rest = REST::Client->new(useragent => $ua);

    my $self = {
	server => $server,
	ua => $ua,
	rest => $rest,
	json => JSON::XS->new,
	(defined($auth_token) ? (auth_token => $auth_token) : ()),

    };
    return bless $self, $class;
}

=head3 $id = $aw->submit($job)

Submit $job to awe; $job is an Awe::JobDescription instance.

=cut

sub submit
{
    my($self, $job) = @_;

    my $json = $job->as_json;
    
    my $url = $self->server . "/job";
    print "SUBMIT to $url\n";
    my $res = $self->ua->post($url,
    			      $self->auth_header(),
			      Content_Type => 'multipart/form-data',
			      Content_Length => length($json),
			      Content => [upload => [undef, 'user_data', Content => $json]]);
    if ($res->is_success)
    {
	my $ret = $self->json->decode($res->content);
	my $id = $ret->{data}->{id};
	return $id;
    }
    else
    {
	die "submit failed: " . $res->content . "\n$json";
    }
}

sub GET
{
    my($self, $query) = @_;
    my $url = $self->server . "/$query";
    my $res = $self->ua->get($url, $self->auth_header());

    if ($res->is_success)
    {
	my $awe_res = $self->json->decode($res->content);
	if ($awe_res->{status} eq 200)
	{
	    return $awe_res;
	}
	else
	{
	    return undef, $awe_res->{error};
	}
    }
    else
    {
	return undef, $res->content;
    }
}

sub job_state
{
    my($self, $job_id) = @_;

    my $url = $self->server . "/job/$job_id";
    my $res = $self->ua->get($url, $self->auth_header());
    if ($res->is_success)
    {
	my $awe_res = $self->json->decode($res->content);
	if ($awe_res->{status} eq 200)
	{
	    my $state = $awe_res->{data}->{state};
	    return $state;
	}
	else
	{
	    return undef, $awe_res->{error};
	}
    }
    else
    {
	return undef, $res->content;
    }
}

sub job
{
    my($self, $job_id) = @_;

    #
    # AWE 0.9.43 returns buggy results when querying with /job/id but correct
    # results when querying with /job?query&id=.
    #
    # my $url = $self->server . "/job/$job_id";
    my $url = $self->server . "/job/?query&id=$job_id";
    my $res = $self->ua->get($url, $self->auth_header());
    if ($res->is_success)
    {
	my $awe_res = $self->json->decode($res->content);
	if ($awe_res->{status} eq 200)
	{
	    my $data = $awe_res->{data};
	    #
	    # If we are doing the query workaround, result data is a list.
	    #
	    $data = $data->[0] if ref($data) eq 'ARRAY';
	    return $data;
	}
	else
	{
	    return undef, $awe_res->{error};
	}
    }
    else
    {
	return undef, $res->content;
    }
}

sub auth_header
{
    my($self) = @_;
    if ($self->auth_token)
    {
	return (Authorization => ("OAuth " . $self->auth_token),
	        Datatoken => $self->auth_token);
    }
    else
    {
	return ();
    }
}

sub create_job_description
{
    my($self, %info) = @_;
    return Bio::KBase::AppService::Awe::JobDescription->new($self, %info);
}

sub create_job_file
{
    my($self, $name, $shock_host, $shock_node) = @_;
    return Bio::KBase::AppService::Awe::JobFile->new($name, $shock_host, $shock_node);
}

package Bio::KBase::AppService::Awe::JobDescription;

use Data::Dumper;
use strict;
use JSON::XS;

sub new
{
    my($class, $awe, %info) = @_;
    my $self = {
	awe => $awe,
	job => {
	    info => { %info },
	    tasks => [],
	},
    };
    return bless $self, $class;
}

sub as_json
{
    my($self) = @_;
    my $json = JSON::XS->new->ascii->pretty->allow_nonref->convert_blessed;
    return $json->encode($self->{job});
}

sub TO_JSON
{
    my($self) = @_;
    return { %{$self->{job}} }; 
}
     
sub add_task
{
    my($self, $description, $cmd, $args, $deps, $inputs, $outputs, $partinfo, $totalwork, $userattr) = @_;

    my $awe = $self->{awe};
    
    $partinfo = {} unless ref($partinfo);
    
    my $taskid = scalar(@{$self->{job}->{tasks}});

    my $input_list = [];
    for my $inp (@$inputs)
    {
	push(@$input_list, {
	    filename => $inp->name,
	    name => $inp->name,
	    host => $inp->host,
	    node => $inp->node,
	    defined($inp->origin) ? (origin => "" . $inp->origin) : (),
	});
    }

    my $output_list = [];
    for my $outp (@$outputs)
    {
	push(@$output_list, {
	    filename => $outp->name,
	    name => $outp->name,
	    host => $outp->host,
	    node => $outp->node,
	});
	my $origin = $outp->origin;
	if (defined($origin))
	{
	    die "Origin already defined for file " . $outp->name;
	}
	$outp->origin($taskid);
    }

    my @environ = ();
#print STDERR Dumper($awe);
    if ($awe->auth_token)
    {
	@environ = (environ => { 
				 private => { KB_AUTH_TOKEN => $awe->auth_token },
				 } );
    }

    my $task = {
	cmd => {
	    args => $args,
	    description => $description,
	    name => $cmd,
	    @environ,
	},
	dependsOn => $deps,
	inputs => $input_list,
	outputs => $output_list,
	partinfo => { %$partinfo },
	taskid => "" . $taskid,
	skip => 0,
	totalwork => ($totalwork || 1),
	defined($userattr) ? (userattr => $userattr) : (),
    };
    push(@{$self->{job}->{tasks}}, $task);
    return $taskid;
}

package Bio::KBase::AppService::Awe::JobFile;

use strict;
use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(name host node origin));

sub new
{
    my($class, $name, $shock_host, $shock_node) = @_;
    my $self = {
	name => $name,
	host => $shock_host,
	node => ($shock_node || "-"),
    };
    return bless $self, $class;
}

sub in_name
{
    my($self) = @_;
    return "@" . $self->name;
}

package Bio::KBase::AppService::JobTask;
use strict;

1;
