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

=head1 MISCELLANY

We force the setting of TZ=UCT before running Slurm commands so that we can consistently
log times reported in UCT.

=head2 METHODS

=over 4

=item B<new>

    $cluster = Bio::KBase::AppService::SlurmCluster->new($id, schema => $schema, %opts)

=over 4

=item Arguments: $id, L<$schema|Bio::KBase::AppService::Schema>

=item Return Value: L<$cluster|Bio::KBase::AppService::SlurmCluster>

=back

Create a new SlurmCluster object. The given C<$id> must exist in the database. C<$schema> is a 
pointer to the DBIx::Class schema for the database.

=cut

sub new
{
    my($class, $id, %opts) = @_;

    #
    # Find sacctmgr in our path to use as the default for the wrapper.
    #

    my $schema = $opts{schema};
    $schema or die "SlurmCluster: schema parameter is required";

    my $cobj = $schema->resultset("Cluster")->find($id);
    $cobj or die "Cannot find cluster $id in database";

    #
    # Set up accountmgr features if we don't have a fixed account
    # to use for this cluster.
    #
    my $sacctmgr;
    if (!$cobj->account)
    {
	my $path = $cobj->scheduler_install_path;
	if ($path)
	{
	    $sacctmgr = "$path/$sacctmgr";
	}
	else
	{
	    $sacctmgr = searchpath('sacctmgr');
	}
	if (!$sacctmgr && ! -x $sacctmgr)
	{
	    warn "Could not find sacctmgr '$sacctmgr' in path";
	}
    }

    my $self = {
	id => $id,
	json => JSON::XS->new->pretty(1)->canonical(1),
	sacctmgr_path => $sacctmgr,
	%opts,
    };

    if ($sacctmgr)
    {
	$self->{sacctmgr} = Slurm::Sacctmgr->new(sacctmgr => $self->{sacctmgr_path});
    }
    
    return bless $self, $class;
}

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

    return if $cinfo->account;

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

=item B<submit_tasks>

    $ok = $cluster->submit_tasks($tasks, $resources)

=over 4

=item Arguments: L<\@tasks|Bio::KBase::AppService::Schema::Result::Task>, \@resources

=item Return value: $status
    
=back

Submit a set of tasks to the cluster.  Returns true if the tasks were submitted. As a side effect
create the L<ClusterJob|Bio::KBase::AppService::Schema::Result::ClusterJob> record for
this task.

All tasks are created in the same cluster job. This logic enables sharing of a single
cluster submission for multiple pieces of work where there is a disconnect between the size
of the smallest possible resource request at the cluster and the maximum amount of CPU
a task can utilize.

If multiple tasks are submitted, we do not use the memory/cpu requirements from
the task; rather we rely on the C<$resources> list which includes the 
sbatch request options required for this submission. (Yes, we are punting here.
This is mostly for the special case of submitting set of tasks to a single node
on a large cluster, where we have cluster-specific options for requesting such a node).

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

=back
    
=head2 ENVIRONMENT SETUP

We use the p3_deployment_path field on the Cluster from the database to find
the deployment to use.  For now we will inline in the startup script the
appropriate environment setup.

We must define for the invoked application the CPU and memory allocation
provided for it. In some cases this comes from the Slurm allocation, in others
(e.g. Bebop) it is a defined fraction of the node resources. In the
latter case we must compute that available resource by querying the node.

In that case, we use C<nproc> to determine processor count and a parse
of the C<free> command to determine available memory.

These parameters are passed to the application by the P3_ALLOCATED_CPU and 
P3_ALLOCATED_MEMORY environment variables.

=cut

sub submit_tasks
{
    my($self, $tasks) = @_;

    return if @$tasks == 0;
    
    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    my $name = join(",", map { $_->application->id } @$tasks);

    #
    # Ensure all of the tasks have the same owner, if we
    # are submitting to a cluster where we don't use a single account.
    #
    my $account = $cinfo->account;
    if (!$account)
    {
	$account = $tasks->[0]->owner->id;
	for my $task (@$tasks[1..$#$tasks])
	{
	    if ($account ne $task->owner->id)
	    {
		die "submit_tasks: Tasks in a set must all have the same owner on this cluster";
	    }
	}

    }

    #
    # compute resource request information.
    # $alloc_env sets the allocation environment vars for the batch
    #

    my $alloc_env;
    my $resource_request;
    my $resources = $self->{resources};
    if (@$tasks > 1 || $resources)
    {
	$resource_request = join("\n", map { "#SBATCH $_" } @$resources);

	my $ntasks = @$tasks;
	$alloc_env = <<EAL;
mem_total=`free -b | grep Mem | awk '{print \$2}'`
proc_total=`nproc`
export P3_ALLOCATED_MEMORY=`expr \$mem_total / $ntasks
export P3_ALLOCATED_CPU=`expr \$proc_total / $ntasks
EAL
    }
    else
    {
	my $task = $tasks->[0];
	my $app = $task->application;

	my $ram = $task->req_memory // $app->default_memory // "1M";
	my $cpu = $task->req_cpu // $app->default_cpu // 1;

	$alloc_env = <<EAL;
export P3_ALLOCATED_MEMORY="\${SLURM_JOB_CPUS_PER_NODE}M"
export P3_ALLOCATED_CPU=\$SLURM_JOB_CPUS_PER_NODE
EAL
	
	$resource_request = <<EREQ
#SBATCH --mem $ram
#SBATCH --ntasks $cpu --cpus-per-task 1
EREQ
    }
    
    my $out_dir = $cinfo->temp_path;
    my $out = "$out_dir/slurm-%j.out";
    my $err = "$out_dir/slurm-%j.err";
    if ($cinfo->remote_host)
    {
	$out = "slurm-%j.out";
	$err = "slurm-%j.err";
    }

    my $top = $cinfo->p3_deployment_path;
    my $rt = $cinfo->p3_runtime_path;
    my $temp = $cinfo->temp_path;

    my $batch = <<END;
#!/bin/sh
#SBATCH --account $account
#SBATCH --job-name $name
$resource_request
#SBATCH --output $out
#SBATCH --err $err

export KB_TOP=$top
export KB_RUNTIME=$rt
export PATH=\$KB_TOP/bin:\$KB_RUNTIME/bin:\$PATH
export PERL5LIB=\$KB_TOP/lib
export KB_DEPLOYMENT_CONFIG=\$KB_TOP/deployment.cfg
export R_LIBS=\$KB_TOP/lib

export PATH=\$PATH:\$KB_TOP/services/genome_annotation/bin
export PATH=\$PATH:\$KB_TOP/services/cdmi_api/bin

export PERL_LWP_SSL_VERIFY_HOSTNAME=0

export TEMPDIR=$temp
export TMPDIR=$temp

$alloc_env
END

    for my $task (@$tasks)
    {
        my $task_id = $task->id;
	my $app = $task->application;
	my $script = $app->script;
	my $spec = $task->app_spec;
	my $params = $task->params;
	# use the token with the longest expiration
	my $token = $task->task_tokens->search(undef, { order_by => {-desc => 'expiration '}})->single()->token;
	
	my $monitor_url = $task->monitor_url;

	$batch .= <<END

# Run task $task_id - $script

export P3_AUTH_TOKEN="$token"

export WORKDIR=$temp/task-$task_id
mkdir \$WORKDIR
cd \$WORKDIR

cat > app_spec <<'EOSPEC'
$spec
EOSPEC

cat > params <<'EOPARAMS'
$params
EOPARAMS

echo "Running script $script"
$script $monitor_url app_spec params &
pid_$task_id=\$!
echo "Task $task_id has pid \$pid_$task_id"

END
    }

    #
    # Now generate the waits.
    #

    for my $task (@$tasks)
    {
	my $task_id = $task->id;
	
	$batch .= <<END;
echo "Wait for task $task_id \$pid_$task_id"
wait \$pid_$task_id
rc_$task_id=\$?
echo "Task $task_id exited with \$rc_$task_id"
END
    }

    #
    # If we have multiple tasks, return success. Otherwise return
    # status of the one task.
    #
    if (@$tasks == 1)
    {
	my $task_id = $tasks->[0]->id;
	$batch .= "exit \$rc_$task_id\n";
    }
    else
    {
	$batch .= "exit 0\n";
    }
    print $batch;

    my $id;
    my $ok = run($self->setup_cluster_command(["sbatch", "--parsable"]), "<", \$batch, ">", \$id,
		 init => sub { $ENV{TZ} = 'UCT'; });
    if ($ok)
    {
	chomp $id;
	print "Batch submitted with id $id\n";
	for my $task (@$tasks)
	{
	    $task->update({state_code => 'S'});
	    $task->add_to_cluster_jobs(
				   {
				       cluster_id => $self->id,
				       job_id => $id,
				   });
	}
    }
    else
    {
	print "Failed to submit batch: $?\n";
	for my $task (@$tasks)
	{
	    $task->update({state_code => 'F'});
	}
    }
    return $ok;
}

=item B<queue_check>

    $cluster->queue_check()

Check and update the status of any queued jobs.

=cut

sub queue_check
{
    my($self) = @_;

    #
    # We need to find the jobs on the cluster for which the state
    # of the associated tasks(s) is S (Submitted to cluster). There may
    # be multiples because the scheduler may have run multiple tasks
    # in a single job in order to share resources.
    #
    # Query distinct here to get the set of cluster jobs. We will
    # update state on all associated tasks. (This may obscure
    # reporting of real execution times for the tasks, but we cannot
    # know that here. Such reporting must be done at either the
    # level of the app-wrapping scripts or the submitted
    # scheduler batch script).
    #

    my @jobs = $self->schema->resultset("ClusterJob")->search({
	cluster_id => $self->id,
	'task.state_code' => 'S',
    }, { join => { task_executions => 'task' }, distinct => 1});

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
    my $h = IPC::Run::start($self->setup_cluster_command(\@cmd), '>pipe', $fh,
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


	    #
	    # Update the associated tasks.
	    #
	    for my $task ($cj->tasks)
	    {
		$task->update({
		    state_code => $code,
		    start_time => $vals->{Start},
		    finish_time => $vals->{End},
		});
	    }
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

=item B<setup_cluster_command>

=over 4

=item Arguments: \@cmd

=item Return Value: \@modified_command

=back

If we are executing on a remote cluster, modify the given
command to be one that does a ssh to the cluster.

=cut

sub setup_cluster_command
{
    my($self, $cmd) = @_;

    my $cinfo = $self->schema->resultset("Cluster")->find($self->id);

    if ($cinfo->remote_host)
    {
	my $new = ["ssh",
		   "-l", $cinfo->remote_user,
		   "-i", $cinfo->remote_keyfile,
		   $cinfo->remote_host,
		   join(" ", map { "'$_'" } "env", "TZ=UCT", @$cmd),
		   ];
	print "@$new\n";
	return $new;
    }
    else
    {
	return $cmd;
    }
	 
}

=back

=cut    


1;
