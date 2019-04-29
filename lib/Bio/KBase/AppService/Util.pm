package Bio::KBase::AppService::Util;
use strict;
use File::Slurp;
use JSON::XS;
use File::Basename;
use Data::Dumper;
use AnyEvent;
use AnyEvent::Run;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(impl scheduler));

sub new
{
    my($class, $impl) = @_;

    my $self = {
	impl => $impl,
    };
    return bless $self, $class;
}

sub start_app
{
    my($self, $ctx, $app_id, $task_params, $start_params) = @_;

    if (!$self->submissions_enabled($app_id, $ctx))
    {
	die "App service submissions are disabled\n";
    }

    my $json = JSON::XS->new->ascii->pretty(1);

    #
    # Create a new workflow for this task.
    #

    my $app = $self->find_app($app_id);

    if (!$app)
    {
	die "Could not find app for id $app_id\n";
    }

    my $awe = Bio::KBase::AppService::Awe->new($self->impl->{awe_server}, $ctx->token);

    my $param_str = $json->encode($task_params);

    #
    # Create an identifier we can use to match the Shock nodes we create for this
    # job with the job itself.
    #

    my $gen = Data::UUID->new;
    my $task_file_uuid = $gen->create();
    my $task_file_id = lc($gen->to_string($task_file_uuid));

    my $userattr = {
	app_id => $app_id,
	parameters => $param_str,
	workspace => $start_params->{workspace},
	parent_task => $start_params->{parent_id},
	task_file_id => $task_file_id,
    };

    my $clientgroup = $self->impl->{awe_clientgroup};

    if ($app_id eq 'MetagenomeBinning' && $task_params->{contigs})
    {
	#  Hack to send contigs-only jobs to a different clientgroup
	$clientgroup .= "-fast";
	print STDERR "Redirecting job to fast queue\n" . Dumper($task_params);
    }
    elsif ($app_id eq 'PhylogeneticTree' && $task_params->{full_tree_method} ne 'ml')
    {
	#  Hack to send non-raxml jobs to a different clientgroup
	$clientgroup .= "-fast";
	print STDERR "Redirecting job to fast queue\n" . Dumper($task_params);
    }
    if ($task_params->{_clientgroup})
    {
	$clientgroup = $task_params->{_clientgroup};
    }
	
    my $job = $awe->create_job_description(pipeline => 'AppService',
					   name => $app_id,
					   project => 'AppService',
					   user => $ctx->user_id,
					   clientgroups => $clientgroup,
					   userattr => $userattr,
					   priority => 2,
					  );

    my $shock = Bio::KBase::AppService::Shock->new($self->impl->{shock_server}, $ctx->token);
    $shock->tag_nodes(task_file_id => $task_file_id,
		      app_id => $app_id);
    my $params_node_id = $shock->put_file_data($param_str, "params");

    my $app_node_id = $shock->put_file_data($json->encode($app), "app");

    my $app_file = $awe->create_job_file("app", $shock->server, $app_node_id);
    my $params_file = $awe->create_job_file("params", $shock->server, $params_node_id);

#    my $stdout_file = $awe->create_job_file("stdout.txt", $shock->server);
#    my $stderr_file = $awe->create_job_file("stderr.txt", $shock->server);
    
    my $awe_stdout_file = $awe->create_job_file("awe_stdout.txt", $shock->server);
    my $awe_stderr_file = $awe->create_job_file("awe_stderr.txt", $shock->server);

    my $appserv_info_url = $self->impl->{service_url} . "/task_info";

    my $task_userattr = {};
    my $task_id = $job->add_task($app->{script},
				 $app->{script},
				 join(" ",
				      $appserv_info_url,
				      $app_file->in_name, $params_file->in_name,
				      # $stdout_file->name, $stderr_file->name,
				     ),
				 [],
				 [$app_file, $params_file],
				 [$awe_stdout_file, $awe_stderr_file],
				 # [$stdout_file, $stderr_file, $awe_stdout_file, $awe_stderr_file],
				 undef,
				 undef,
				 $task_userattr,
				);

    # print STDERR Dumper($job);

    my $task_id = $awe->submit($job);

    my $task = $self->impl->_lookup_task($awe, $task_id);

    return $task;
}

sub start_app_with_preflight
{
    my($self, $ctx, $app_id, $task_params, $start_params) = @_;

    if (!$self->submissions_enabled($app_id, $ctx))
    {
	die "App service submissions are disabled\n";
    }

    my $json = JSON::XS->new->ascii->pretty(1);

    #
    # Create a new workflow for this task.
    #

    my $app = $self->find_app($app_id);
    if (!$app)
    {
	die "Could not find app for id $app_id\n";
    }

    my $appserv_info_url = $self->impl->{service_url} . "/task_info";

    my $app_tmp = File::Temp->new();
    print $app_tmp $json->encode($app);
    close($app_tmp);

    my $params_tmp = File::Temp->new();
    print $params_tmp $json->encode($task_params);
    close($params_tmp);

    my $preflight_tmp = File::Temp->new();
    close($preflight_tmp);

    return sub {
	my($cb) = @_;
	print STDERR "got cb=$cb\n";

	my $cmd = [$app->{script}, "--preflight", "$preflight_tmp", $appserv_info_url, "$app_tmp", "$params_tmp"];
	print STDERR "cmd: @$cmd\n";

	my $handle;
	$handle = AnyEvent::Run->new(cmd => $cmd,
					on_read => sub {
					    my $rh = shift;
					    print STDERR "GOT $rh->{rbuf}\n";
					    $rh->{rbuf} = '';
					},
					on_error => sub {
					    my($rh, $fatal, $message) = @_;
					    print STDERR "Error on preflight read: $message\n";
					    if ($fatal)
					    {
						$cb->({message => "preflight error: $message"});
						undef $handle;
					    }
					},
					on_eof => sub {
					    print STDERR "Preflight EOF $handle\n";
					    my @temps = ($params_tmp, $app_tmp, $preflight_tmp);
					    system("cat", $preflight_tmp);

					    eval {
						$self->continue_submit($ctx, $cb, $appserv_info_url, $preflight_tmp, $app, $task_params, $start_params);
					    };
					    if ($@)
					    {
						print STDERR "Submit error: $@";
						$cb->({message => "error submitting: $@"});
					    }
					    undef $handle;
					}
				    );
    };
}

=item B<continue_submit>

Preflight has successfully completed. Continue submission.

=cut

sub continue_submit
{
    my($self, $ctx, $cb, $info_url, $preflight_file, $app, $task_params, $start_params) = @_;
    my $txt = read_file("$preflight_file");
    my $preflight = $txt ? decode_json($txt) : {};
    print STDERR Dumper(PREFLIGHT => $preflight);
    print STDERR "'$txt'\n";
    my $task = $self->scheduler->start_app(P3AuthToken->new(token => $ctx->token),
					   $app->{id}, $info_url, $task_params, $start_params, $preflight);
    my $ret_task  = {
	id => $task->id,
	parent_id => $start_params->{parent_id},
	parameters => $task_params,
	user_id => $ctx->user_id,
	status => $task->state_code->code,
    };
    print Dumper($ret_task);
    $cb->([$ret_task]);
}

sub enumerate_apps
{
    my($self) = @_;

    my $dh;
    my $dir = $self->impl->{app_dir};

    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    my @list;
    
    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = sort { $a cmp $b } grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = $json->decode(scalar read_file("$dir/$f"));
	    if (!$obj)
	    {
		warn "Could not read $dir/$f\n";
	    }
	    else
	    {
		push(@list, $obj);
	    }
	}
    } else {
	warn "Could not open app-dir $dir: $!";
    }
    return @list;
}

sub find_app
{
    my($self, $app_id) = @_;

    my $dh;
    my $dir = $self->impl->{app_dir};

    my @list;
    
    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = $json->decode(scalar read_file("$dir/$f"));
	    if (!$obj)
	    {
		warn "Could not read $dir/$f\n";
	    }
	    else
	    {
		if ($obj->{id} eq $app_id)
		{
		    return $obj;
		}
	    }
	}
    } else {
	warn "Could not open app-dir $dir: $!";
    }
    return undef;
}

sub service_status
{
    my($self, $ctx) = @_;
    #
    # Status file if it exists is to have the first line containing a numeric status (0 for down
    # 1 for up). Any further lines contain a status message.
    #

    if ($self->token_user_is_admin($ctx->{token}))
    {
	return (1, "");
    }
    
    my $sf = $self->impl->{status_file};
    if ($sf && open(my $fh, "<", $sf))
    {
	my $statline = <$fh>;
	my($status) = $statline =~ /(\d+)/;
	$status //= 0;
	my $txt = join("", <$fh>);
	close($fh);
	return($status, $txt);
    }
    else
    {
	return(1, "");
    }
}

#
# A service status of 0 means submissions are disabled.
#
sub submissions_enabled
{
    my($self, $app_id, $ctx) = @_;

    my($stat, $txt) = $self->service_status($ctx);

    #
    # If an app id was submitted, check to see if that particular service
    # is disabled.
    #
    # The status file for services is in the same directory as the overall
    # service status file. (A little hacky but ...)
    #

    if ($self->token_user_is_admin($ctx->token))
    {
	return 1;
    }

    if ($stat && defined($app_id) && $self->impl->{status_file})
    {
	my $app_status_dir = dirname($self->impl->{status_file});
	my $app_status_file = "$app_status_dir/$app_id.status";
	if (open(my $fh, $app_status_file))
	{
	    my $statline = <$fh>;
	    close($fh);
	    my($status) = $statline =~ /(\d+)/;
	    $status //= 1;
	    return $status;
	}
    }

    return $stat;
}

sub get_task_exitcode
{
    my($self, $id) = @_;
    my $tdir = $self->impl->{task_status_dir};
    if (open(my $fh, "<", "$tdir/$id/exitcode"))
    {
	my $l = <$fh>;
	close($fh);
	if ($l =~ /(\d+)/)
	{
	    return $1;
	}
	else
	{
	    warn "Invalid exitcode file $tdir/$id/exitcode\n";
	    return undef;
	}
    }
    else
    {
	return undef;
    }
}

sub token_user_is_admin
{
    my($self, $token) = @_;
    $token = $token->token if ref($token);

    #
    # Let admins (Bob for now) submit when the service is down.
    #
    my($user_id) = $token =~ /\bun=([^|]+)/;
    return $user_id eq 'olson@patricbrc.org';
}


1;
