package Bio::KBase::AppService::Util;
use strict;
use File::Slurp;
use JSON::XS;
use File::Basename;
use Data::Dumper;
use AnyEvent;
use AnyEvent::Run;
use IPC::Run;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(impl));

sub new
{
    my($class, $impl) = @_;

    my $self = {
	impl => $impl,
    };
    return bless $self, $class;
}

sub json
{
    my($self) = @_;
    my $json = $self->{json};
    if (!$json)
    {
	$self->{json} = $json = JSON::XS->new->ascii->pretty(1);
    }
    return $json;
}


=head3

    stat_app_with_preflight()

We use p3x-submit-job to do the actual job submission; this way we can
perform the database and preflight executions synchronously and allow
the method here to asynchronously await its completion. If necessary we can
protect the process by using a semaphore or queue to limit the active number
of preflight computations.

=cut    

sub start_app_with_preflight
{
    my($self, $ctx, $app_id, $task_params, $start_params) = @_;

    if (!$self->submissions_enabled($app_id, $ctx))
    {
	die "App service submissions are disabled\n";
    }

    my $task_params_tmp = File::Temp->new();
    print $task_params_tmp $self->json->encode($task_params);
    close($task_params_tmp);

    my $start_params_tmp = File::Temp->new();
    print $start_params_tmp $self->json->encode($start_params);
    close($start_params_tmp);

    my $task_tmp = File::Temp->new();
    close($task_tmp);

    return sub {
	my($cb) = @_;
	print STDERR "got cb=$cb\n";

	my $cmd = ["p3x-submit-job", $ctx->token, $app_id, "$task_params_tmp", "$start_params_tmp", "$task_tmp"];
	print STDERR "cmd: @$cmd\n";

	my $handle;
	my $output;

	$handle = AnyEvent::Run->new(cmd => $cmd,
					on_read => sub {
					    my $rh = shift;
					    print STDERR "GOT $rh->{rbuf}\n";
					    $output .= $rh->{rbuf};
					    $rh->{rbuf} = '';
					},
					on_error => sub {
					    my($rh, $fatal, $message) = @_;
					    print STDERR "Error on submit read: $message\n";
					    if ($fatal)
					    {
						$cb->({message => "submit error: $message"});
						undef $handle;
					    }
					},
					on_eof => sub {
					    print STDERR "Submit EOF $handle\n";

					    #
					    # Keep our temps alive and on disk.
					    #
					    my @temps = ($task_params_tmp, $start_params_tmp);
					    eval {
						$self->continue_submit($ctx, $cb, $output, $start_params, $task_tmp);
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

p3x-submit-job has completed.

=cut

sub continue_submit
{
    my($self, $ctx, $cb, $output, $start_params, $task_tmp) = @_;

    if (-f "$task_tmp")
    {
	my $data = read_file("$task_tmp");
	
	my $ret_task = eval { $self->json->decode($data) };
	if ($@)
	{
	    print STDERR "Error parsing generated task data:\n$data\n";
	    $cb->([]);
	}
	else
	{
	    print STDERR Dumper($ret_task);
	    $cb->([$ret_task]);
	}
    }
    else
    {
	print STDERR "No task tmp file $task_tmp generated\n";
	$cb->([]);
    }
}

# synchronous version

sub start_app_with_preflight_sync
{
    my($self, $ctx, $app_id, $task_params, $start_params) = @_;

    if (!$self->submissions_enabled($app_id, $ctx))
    {
	die "App service submissions are disabled\n";
    }

    my $task_params_tmp = File::Temp->new();
    print $task_params_tmp $self->json->encode($task_params);
    close($task_params_tmp);

    my $start_params_tmp = File::Temp->new();
    print $start_params_tmp $self->json->encode($start_params);
    close($start_params_tmp);

    my $task_tmp = File::Temp->new();
    close($task_tmp);

    my $user_tmp = File::Temp->new();
    close($user_tmp);

    my $cmd = ["p3x-submit-job",
	       "--user-error-file", "$user_tmp",
	       $ctx->token, $app_id, "$task_params_tmp", "$start_params_tmp", "$task_tmp"];
    print STDERR "cmd: @$cmd\n";
    
    my $output;
    my $error;

    my $ok = IPC::Run::run($cmd,
			   ">", \$output,
			   "2>", \$error);

    close($user_tmp);
	  
    if (!$ok)
    {
	my $out = read_file("$user_tmp");
	die "Error submitting job: $out\n";
    }

    if (-f "$task_tmp")
    {
	my $data = read_file("$task_tmp");
	
	my $ret_task = eval { $self->json->decode($data) };
	if ($@)
	{
	    die "Error parsing generated task data:\n$data\n";
	}
	else
	{
	    return $ret_task;
	}
    }
    else
    {
	die "No task tmp file $task_tmp generated\n";
    }
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

sub kill_tasks
{
    my($self, $user_id, $tasks) = @_;

    return $self->scheduler->kill_tasks($user_id, $tasks);
}

1;
