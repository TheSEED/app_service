package Bio::KBase::AppService::SlurmCluster;

use 5.010;
use strict;
use Bio::KBase::AppService::Schema;
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use EV;
use AnyEvent;
use JSON::XS;
use Slurm::Sacctmgr;
use Slurm::Sacctmgr::Account;
use Slurm::Sacctmgr::Association;
use File::SearchPath qw(searchpath);
use File::Path qw(make_path);
use IPC::Run qw(run);
use IO::Handle;

__PACKAGE__->mk_accessors(qw(id schema json sacctmgr sacctmgr_path
			    ));

# value is true if it is a terminal state; the value is the
# TaskState code for that terminal state

our %job_states =
    (
     BOOT_FAIL => 'F',
     CANCELLED => 'F',
     COMPLETED => 'C',
     DEADLINE => 'F',
     FAILED => 'F',
     NODE_FAIL => 'F',
     OUT_OF_MEMORY => 'F',
     PENDING => 0,
     PREEMPTED => 0,
     RUNNING => 0,
     REQUEUED => 0,
     RESIZING => 0,
     REVOKED => 'F',
     SUSPENDED => 0,
     TIMEOUT => 'F',
    );

=head1 NAME

Bio::KBase::AppService::SlurmCluster - cluster wrapper for SLURM submissions

=head1 SYNOPSIS

    $slurm = Bio::KBase::AppService::SlurmCluster->new($cluster_id, schema => $schema)

=head1 DESCRIPTION

A SlurmCluster instance represents a particular SLURM cluster in the infrastructure.

The scheduler database maintains a record for each cluster; at this point the only
metadata kept in the database are the cluster name and the base path of the 
installation on the filesystem. This is sufficient to submit to a SLURM cluster.

=head1 USER ACCOUNTING

In this architecture each submission to SLURM requires a SLURM account. The account
name represents the user account from the submitting web service (PATRIC or RAST). 

PATRIC account names are suffixed with @patricbrc.org as they come in from the PATRIC
accounting system.

Submissions with account names without a prefix will have @rast.nmpdr.org added.

All web service jobs will execute under Unix run account that the service is executing
under. 

If the account is not known to the SLURM account manager, a new account will be created.

We have the following account hierarchy defined:

   webservice
   +-- PATRIC
       +-- user1@patricbrc.org
       +-- user2@patricbrc.org
       +-- ...
   +-- RAST
       +-- user3@rast.nmpdr.org
       +- ...

=HEAD1 Miscellany
    
We force the setting of TZ=UCT before running Slurm commands so that we can consistently
log times reported in UCT.

=cut

sub new
{
    my($class, $id, %opts) = @_;

    #
    # Find sacctmgr in our path to use as the default for the wrapper.
    #
    my $sacctmgr = searchpath('sacctmgr');
    if (!$sacctmgr)
    {
	warn "Could not find sacctmgr in path";
    }

    my $self = {
	id => $id,
	json => JSON::XS->new->pretty(1)->canonical(1),
	sacctmgr_path => $sacctmgr,
	%opts,
    };

    $self->{sacctmgr} = Slurm::Sacctmgr->new(sacctmgr => $self->{sacctmgr_path});

    return bless $self, $class;
}

=head2 Methods

=over 4

=item B<configure_user>

    $cluster->configure_user($user)

=over 4

=item Arguments: L<$user|Bio::KBase::AppService::Schema::Result::ServiceUser>

=back

Configure accounting for the provided new user.

=cut

sub configure_user
{
    my($self, $user) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    #
    # See if SLURM has this user already.
    #
    my $mgr = Slurm::Sacctmgr::Account->new;
    my $suser = $mgr->new_from_sacctmgr_by_name($self->sacctmgr, $user->id);
    if ($suser)
    {
	print "Slurm already has " . $user->id . ": " . Dumper($suser);
    }
    else
    {
	my $desc = "";
	if ($user->first_name)
	{
	    $desc = $user->first_name . " " . $user->last_name;
	}
	$desc .= " <" . $user->email . ">" if $user->email;

	my $output = eval { $mgr->sacctmgr_add($self->sacctmgr,
					       name => $user->id,
					       parent => $user->project_id,
					       description => $desc,
					       organization => $user->affiliation) };
	if ($@)
	{
	    warn "Account add failed: $@";
	}
	print $_ foreach @$output;
			    
    }
}

=item B<submit_task>

    $ok = $cluster->submit_task($task)

=over 4

=item Arguments: L<$task|Bio::KBase::AppService::Schema::Result::Task>

=item Return value: $status
    
=back

Submit a task to the cluster.  Returns true if the task was submitted. As a side effect
create the L<ClusterJob|Bio::KBase::AppService::Schema::Result::ClusterJob> record for
this task.
    
For the submission, we create a batch script with the following options

=over 4

=item --account  account-name

Name of user account for this submission.

=item --job-name task-id

Name the job by the task id.

=item --mem required-memory

Request the given amount of RAM.

=item --ntasks tasks --cpus-per-task 1

Request the given number of tasks (cpus).

=item --output output-file

=item --error error-file

Specify the location of standard output and standard error logging.

These are paths on the execution host; for now we will assume a common location
(L<< $self->exec_host_output_dir >>).

Slurm doesn't set any policy for us and will notably drop the job
into the working directory of the invoking script or into a
directory defined by the --chdir flag.

We use the p3_deployment_path field on the Cluster from the database to find
the deployment to use.  For now we will inline in the startup script the
appropriate environment setup. 

=back
    
=cut

sub submit_task
{
    my($self, $task) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    my $app = $task->application;
    say "Submitting application  " . $app->id;
    my $account = $task->owner->id;
    my $task_id = $task->id;
    my $name = "as-" . $task->id;
    my $script = $app->script;
    my $ram = $app->default_memory // "1M";
    my $cpu = $app->default_cpu // 1;
    my $out_dir = $cinfo->temp_path;
    my $out = "$out_dir/slurm-%j.out";
    my $err = "$out_dir/slurm-%j.err";

    my $top = $cinfo->p3_deployment_path;
    my $rt = $cinfo->p3_runtime_path;
    my $temp = $cinfo->temp_path;

    my $spec = $task->app_spec;
    my $params = $task->params;
    # use the token with the longest expiration
    my $token = $task->task_tokens->search(undef, { order_by => {-desc => 'expiration '}})->single();

    my $monitor_url = $task->monitor_url;

    my $batch = <<END;
#!/bin/sh
#SBATCH --account $account
#SBATCH --job-name $name
#SBATCH --mem $ram
#SBATCH --ntasks $cpu --cpus-per-task 1
#SBATCH --output $out
#SBATCH --err $err

export KB_TOP=$top
export KB_RUNTIME=$rt
export PATH=\$KB_TOP/bin:\$KB_RUNTIME/bin:\$PATH
export PERL5LIB=\$KB_TOP/lib
export KB_SERVICE_DIR=\$KB_TOP/services/awe_service
export KB_DEPLOYMENT_CONFIG=\$KB_TOP/deployment.cfg
export R_LIBS=\$KB_TOP/lib

export PATH=\$PATH:\$KB_TOP/services/genome_annotation/bin
export PATH=\$PATH:\$KB_TOP/services/cdmi_api/bin

export PERL_LWP_SSL_VERIFY_HOSTNAME=0

export TEMPDIR=$temp
export TMPDIR=$temp

export WORKDIR=$temp/task-$task_id
mkdir \$WORKDIR
cd \$WORKDIR

export P3_AUTH_TOKEN="$token"

cat > app_spec <<'EOSPEC'
$spec
EOSPEC

cat > params <<'EOPARAMS'
$params
EOPARAMS

echo "Running script $script"
$script $monitor_url app_spec params
rc=\$?
echo "Script $script finishes with exit code \$rc"

exit \$rc
    
END

    my $id;
    my $ok = run(["sbatch", "--parsable"], "<", \$batch, ">", \$id,
		 init => sub { $ENV{TZ} = 'UCT'; });
    if ($ok)
    {
	chomp $id;
	print "Batch submitted with id $id\n";
	$task->update({state_code => 'S'});
	$task->create_related("cluster_jobs",
			  {
			      cluster_id => $self->id,
			      job_id => $id,
			  });
    }
    else
    {
	print "Failed to submit batch: $?\n";
	$task->update({state_code => 'F'});
    }
}

=item B<queue_check>

    $cluster->queue_check()

Check and update the status of any queued jobs.

=cut

sub queue_check
{
    my($self) = @_;

    my @jobs = $self->schema->resultset("ClusterJob")->search({ cluster_id => $self->id, 'task.state_code' => 'S'}, { join => 'task' });

    if (@jobs == 0)
    {
	print "No jobs\n";
	return;
    }

    my $jobspec = join(",", map { $_->job_id } @jobs);

    #
    # We can use sacct to pull data from all jobs, including currently running.
    # We can thus get all data in a single lookup.
    #

    my @params = qw(JobID State Account User MaxRSS ExitCode Elapsed Start End NodeList);
    my %col = map { $params[$_] => $_ } 0..$#params;

    my @cmd = ('sacct', '-j', $jobspec,
	       '-o', join(",", @params),
	       '--units', 'M',
	       '--parsable', '--noheader');
    my $fh = IO::Handle->new;
    my $h = IPC::Run::start(\@cmd, '>pipe', $fh,
			    init => sub { $ENV{TZ} = 'UCT'; });
    if (!$h)
    {
	warn "Error $? checking queue : @cmd\n";
	return;
    }

    my %jobinfo;

    #
    # To integrate data from the "id" and "id.batch" lines we read all data first.
    # Pull job state and start times from "id" lines, the other data from "id.batch"
    #

    while (<$fh>)
    {
	chomp;
	my @a = split(/\|/);
	my %vals = map { $_ => $a[$col{$_}] } @params;
	my($id, $isbatch) = $vals{JobID}  =~ /(\d+)(\.batch)?/;
	# print "$id: " . Dumper(\%vals);

	if ($isbatch)
	{
	    $jobinfo{$id} = { %vals };
	}
	else
	{
	    $jobinfo{$id}->{Start} = $vals{Start} unless $vals{Start} eq 'Unknown';
	    $jobinfo{$id}->{State} = $vals{State};
	    $jobinfo{$id}->{NodeList} = $vals{NodeList};
	}
    }
    # print Dumper(\%jobinfo);

    if (!$h->finish)
    {
	warn "Error $? on sstat\n";
    }
    
	
    for my $cj (@jobs)
    {
	my $job_id = $cj->job_id;
	my $vals = $jobinfo{$job_id};


	#
	# Code is true if the new job state is a terminal state.
	# Pull final results.
	#
	my $code = $job_states{$vals->{State}};
	if ($code)
	{
	    my($rss) = $vals->{MaxRSS} =~ /(.*)M$/;
	    $rss = 0 if $vals->{MaxRSS} == 0;

	    print "Job $job_id done " . Dumper($vals);
	    $cj->update({
		job_status => $vals->{State},
		maxrss => $rss,
		exitcode => $vals->{ExitCode},
		($vals->{NodeList} ne '' ? (nodelist => $vals->{NodeList}) : ()),
	    });

	    $cj->task->update({
		state_code => $code,
		start_time => $vals->{Start},
		finish_time => $vals->{End},
	    });
	}
	else
	{
	    print "Job $job_id update " . Dumper($vals);
	    # job is still running; just update state and node info.
	    if ($cj->job_status ne $vals->{State})
	    {
		$cj->update({
		    job_status => $vals->{State},
		    ($vals->{NodeList} ne '' ? (nodelist => $vals->{NodeList}) : ()),
		});
	    }
	}
    }
}

=back

=cut    


1;
