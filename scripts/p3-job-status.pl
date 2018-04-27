=head1 Check job status

    p3-job-status jobid [jobid...]

Check the status of one or more PATRIC jobs.

=head1 Usage synopsis

=cut

use strict;
use Getopt::Long::Descriptive;
use Bio::KBase::AppService::Client;
use P3AuthToken;
use Try::Tiny;
use IO::Handle;
use Data::Dumper;
use LWP::UserAgent;

use JSON::XS;

my $json = JSON::XS->new->pretty(1);
my $ua = LWP::UserAgent->new();
my $token = P3AuthToken->new();
if (!$token->token())
{
    die "You must be logged in to PATRIC via the p3-login command to check job status.\n";
}

my $app_service = Bio::KBase::AppService::Client->new();

my($opt, $usage) =
    describe_options("%c %o jobid [jobid...]",
		     ["Check the status of one or more PATRIC jobs."],
		     [],
		     ["stdout=s", "Write the job's stdout to the given file. Use - to write to terminal.\n"],
		     ["stderr=s", "Write the job's stderr to the given file. Use - to write to terminal.\n"],
		     ["verbose|v", "Show all information for the given jobs."],
		     ["help|h", "Show this help message"],
		    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV == 0;

my @jobs = @ARGV;

#
# This should move into the app service client api ...
#
my %final_states = map { $_ => 1 } qw(suspend completed user_skipped skipped passed);

my $res = $app_service->query_tasks(\@jobs);

for my $job (@jobs)
{
    my $stat = $res->{$job};
    if (!$stat)
    {
	print "$job: job not found\n";
	next;
    }

    my $completion_status = $stat->{status};
    print "$job: $completion_status\n";
    my $details;
    if ($opt->verbose || $opt->stdout || $opt->stderr)
    {
	$details = $app_service->query_task_details($job);
    }
    if ($opt->verbose)
    {
	print "\texecution host\t$details->{hostname}\n";
	print "\tresult code\t$details->{exitcode}\n";
	#
	# these aren't used and are misleading
	#
	delete $stat->{awe_stderr_shock_node};
	delete $stat->{awe_stdout_shock_node};
	print $json->encode($stat);
    }

    if ($opt->stdout)
    {
	write_output($details->{stdout_url}, $opt->stdout);
    }
    if ($opt->stderr)
    {
	write_output($details->{stderr_url}, $opt->stderr);
    }
}

sub write_output
{
    my($url, $file) = @_;
    my $fh;
    if ($file eq '-')
    {
	open($fh, ">&STDOUT");
    }
    else
    {
	open($fh, ">", $file) or die "Cannot open " . $file . ": $!";
    }

    $ua->get($url, ':content_cb' => sub {
	my($data) = @_;
	print $fh $data;
    });
    close($fh);
}
