

package Bio::KBase::AppService::BebopBinning;
use Data::Dumper;
use strict;
use JSON::XS;
use File::Temp;
use IPC::Run;
use Bio::P3::Workspace::WorkspaceClientExt;
use P3AuthToken;

use base 'Class::Accessor';


__PACKAGE__->mk_accessors(qw(json user key host));

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

sub new
{
    my($class, %opts) = @_;

    my $self = {
	json => JSON::XS->new->pretty(1),
	host => 'bebop.lcrc.anl.gov',
#	host => 'beboplogin1.lcrc.anl.gov',
	%opts,
    };
    return bless $self, $class;
}

sub assemble_paired_end_libs
{
    my($self, $ws_path, $libs, $task_id) = @_;

    my $ws = Bio::P3::Workspace::WorkspaceClientExt->new;

    my @errs;
    my $comp_size;
    my $uncomp_size;
    for my $f ($libs->{read1}, $libs->{read2})
    {
	my $s = $ws->stat($f);
	
	if (!$s)
	{
	    push(@errs, "File $f does not exist");
	}
	elsif ($s->size == 0)
	{
	    push(@errs, "File $f has zero size");
	}
	else
	{
	    if ($ws->file_is_gzipped($f))
	    {
		$comp_size += $s->size;
	    } else {
		$uncomp_size += $s->size;
	    }
	}
    }
    if (@errs)
    {
	die "Error checking input data: @errs\n";
    }
	
    my $est_comp = $comp_size + 0.75 * $uncomp_size;
    $est_comp /= 1e6;
    #
    # Estimated conservative rate is 10sec/MB for compressed data under 1.5G, 4sec/GM for data over that.
    my $est_time = int($est_comp < 1500 ? (10 * $est_comp) : (4 * $est_comp));

    $est_time *= 10;
    my $est_time_min = $est_time / 60;
    print STDERR "Raw estimated time: $est_time_min\n";
    $est_time_min = ($est_time_min < 60) ? 60 : int($est_time_min);
    $est_time_min = 1440 if $est_time_min > 1440;
    print STDERR "Submitted estimated time: $est_time_min\n";

    # Estimated compressed storage based on input compressed size, converted at 75% compression estimate.
    #
    # Add an additional 2*est_comp factor since we have the repaired data + trimmed data to store.
    #
    my $est_storage = int(3.3e6 * $est_comp / 0.75);

    print "est_storage=$est_storage\n";
    
    my $partition = "bdwall";

    if ($est_storage > 3e9)
    {
	$partition = "bdwd";
    }
    my $input = $self->json->encode($libs);
    
    my $top = '/home/olson/P3/bebop/dev_container';
    my $rt = '/home/olson/P3/bebop/runtime';
    my $submit_home = '/lcrc/project/PATRIC/submit-home';

    my $token = P3AuthToken->new();
    my $token_txt = $token->token();

    my $batch = <<ENDBATCH;
#!/bin/sh
#SBATCH --job-name=$task_id
#SBATCH -N 1
#SBATCH -p $partition
#SBATCH -A PATRIC
#SBATCH --ntasks-per-node=1
#SBATCH --time=$est_time_min
#SBATCH --chdir $submit_home

export KB_TOP=$top
export KB_RUNTIME=$rt
export PATH=\$KB_TOP/bin:\$KB_RUNTIME/bin:\$PATH
export PERL5LIB=\$KB_TOP/lib
export KB_DEPLOYMENT_CONFIG=\$KB_TOP/deployment.cfg
export R_LIBS=\$KB_TOP/lib

export PATH=\$PATH:\$KB_TOP/services/genome_annotation/bin
export PATH=\$PATH:\$KB_TOP/services/cdmi_api/bin

export PERL_LWP_SSL_VERIFY_HOSTNAME=0

export KB_AUTH_TOKEN="$token_txt"

module add jdk
p3x-run-spades-for-binning --threads 36 --memory 128 "$ws_path" <<'ENDINP'

$input
ENDINP
ENDBATCH

    my($out, $fh);
    while (1)
    {
	
	if (1)
	{
	    my $dbatch = $batch;
	    $dbatch =~ s/sig=[a-z0-9]+/sig=XXX/g;
	    print STDERR "Submitting:\n$dbatch\n";
	}
	
	my $err;
	my($fh, $handle) = $self->run(["sbatch", "--parsable"], $batch, \$out, \$err);
	
	if (!$handle)
	{
	    die "Error issuing submission\n";
	}
	
	if (!$handle->finish)
	{
	    #
	    # See if we failed with permission denied; that means likely the machine
	    # is in maint mode. Retry after a bit.
	    #
	    if ($err =~ /Permission denied/)
	    {
		warn "Error accessing service: $err\nSleeping and retrying\n";
		close($fh) if $fh;
		sleep 60;
	    }
	    else
	    {
		die "Sbatch submit failed: $?";
	    }
	}
	else
	{
	    last;
	}
    }

    my $job;
    print "Output is $out\n";
    if ($out =~ /(\d+)/)
    {
	$job = $1;
	print "Have job $job\n";
    }


    if (!$job)
    {
	print $batch;
	die "Job did not start\n";
    }
    print "Submitted job $job\n";

    my $final_state;
    my $final_res;
    while (1)
    {
	my $res = $self->run_sacct([$job]);
	if ($res)
	{
	    my($sword) = $res->{$job}->{State} =~ /^(\S+)/;
	    my $state = $job_states{$sword};
	    print STDERR Dumper($state, $res);
	    if ($state)
	    {
		$final_state = $state;
		$final_res = $res->{$job};
		last;
	    }
	}
	sleep 120;
    }

    if ($final_state eq 'C')
    {
	print "Assembly successful\n";
    }
    else
    {
	die "Assembly failed with state $final_res->{$job}->{State}\n";
    }
}

sub assemble_srr_ids
{
    my($self, $srrs) = @_;
    die Dumper(srr => $srrs);
}

sub run_sbatch
{

}

sub run_sacct
{
    my($self, $jobs) = @_;
    my $jobspec = join("", @$jobs);

    my @params = qw(JobID State Account User MaxRSS ExitCode Elapsed Start End NodeList);
    my %col = map { $params[$_] => $_ } 0..$#params;
    
    my @cmd = ('sacct', '-j', $jobspec,
	                      '-o', join(",", @params),
	                      '--units', 'M',
	                      '--parsable', '--noheader');
    

    my $err;
    my($fh, $handle) = $self->run(\@cmd, undef, undef, \$err);

    if (!$handle)
    {
	warn "Error checking sacct: $? $!\n";
	return;
    }

    my %jobinfo;

    #
    # To integrate data from the "id" and "id.batch" lines we read all data first.
    # Pull job state and start times from "id" lines, the other data from "id.batch"
    #

    my %jobinfo;

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
    if (!$handle->finish())
    {
	if ($err =~ /Permission denied/)
	{
	    warn "Perm denied error from status check\n";
	}
	else
	{
	    warn "Error from status check: $err\n";
	}
    }

    return \%jobinfo;
}

sub run
{
    my($self, $cmd, $input, $output, $error) = @_;

    my $shcmd = join(" ", map { "'$_'" }  @$cmd);
    
    my $new = ["ssh",
	       ($self->user ? ("-l", $self->user) : ()),
	       ($self->key ? ("-i", $self->key) : ()),
	       $self->host,
	       "bash -l -c \"$shcmd\"",
	       ];

    my $fh;

    my @inp;
    if ($input)
    {
	@inp = ("<", \$input);
    }
    my @out;
    if ($output)
    {
	@out = (">", $output);
    }
    else
    {
	$fh = IO::Handle->new;
	@out = (">pipe", $fh);
    }
    my @err;
    if ($error)
    {
	@err = ('2>', $error);
    }

    my $stderr;
    # print STDERR Dumper($new, \@inp, \@out);
    my $h = IPC::Run::start($new, @inp, @out, @err);
    if (!$h)
    {
	warn "Error $? running : @$cmd\n";
	return;
    }
    return ($fh, $h);
}

1;
