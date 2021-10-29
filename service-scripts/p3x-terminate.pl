=head1 NAME
    
    p3x-terminate - terminate one or more jobs
    
=head1 SYNOPSIS

    p3x-terminate [OPTION]... jobid [jobid...]
    
=head1 DESCRIPTION

Terminate the given jobs. Must be run as the slurm or p3 user.

=cut

use 5.010;    
use strict;
use DBI;
use Data::Dumper;
use DateTime;
use JSON::XS;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name);
use Bio::P3::Workspace::WorkspaceClientExt;

use Getopt::Long::Descriptive;

my $user = getpwuid($>);

unless ($user eq "p3" || $user eq "slurm")
{
    die "$0 must be run as user p3 or slurm\n";
}

my($opt, $usage) = describe_options("%c %o [jobid...]",
				    ["ids-from=s" => "Use the given file to read IDs from"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;

my $port = sched_db_port // 3306;
my $dbh = DBI->connect("dbi:mysql:" . sched_db_name . ";host=" . sched_db_host . ";port=$port",
		       sched_db_user, sched_db_pass);
$dbh or die "Cannot connect to database: " . $DBI::errstr;
$dbh->do(qq(SET time_zone = "+00:00"));

my @ids;
if ($opt->ids_from)
{
    my $fh;
    if ($opt->ids_from eq '-')
    {
	$fh = \*STDIN;
    }
    else
    {
	open($fh, "<", $opt->ids_from) or die "Cannot open " . $opt->ids_from . ": $!\n";
    }
    while (<$fh>)
    {
	if (/^\s*(\d+)/)
	{
	    push(@ids, $1);
	}
    }
    close $fh unless $opt->ids_from eq '-';
}
else
{
    @ids = @ARGV;
}

exit 0 if @ids == 0;

#
# For each job, change the status to T (terminated).
#
# If the job is queued or running in the cluster, issue a scancel.
#

my $q = join(",", map { "?" } @ids);
my $res = $dbh->selectall_hashref(qq(SELECT t.id, t.owner, t.state_code, cj.job_status, cj.job_id
				      FROM Task t
				      LEFT OUTER JOIN TaskExecution te ON t.id = te.task_id
				      LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
				      WHERE
				      t.id IN ($q) AND
				      t.state_code IN ('S', 'Q') AND
				      (te.active = 1 OR te.active IS NULL)), 'id', undef, @ids);

my @to_cancel = map { $_->{job_id} } grep { $_->{state_code} eq 'S' } values %$res;

if (@to_cancel)
{
    my $rc = system("/disks/patric-common/slurm/bin/scancel", @to_cancel);
}

#
# We don't mark the canceled jobs as terminated; we let the scheduler mark them canceled.
#
my @to_terminate = map { $_->{id} } grep { $_->{state_code} eq 'Q' } values %$res;
print "Terminate: @to_terminate\n";

if (@to_terminate)
{
    my $q = join(",", map { "?" } @to_terminate);

    my $done = $dbh->do(qq(UPDATE Task
			   SET state_code = 'T'
			   WHERE id IN ($q)), undef, @to_terminate);
    print Dumper($done);
}




