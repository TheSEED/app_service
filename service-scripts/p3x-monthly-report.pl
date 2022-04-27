=head1 NAME

    p3x-monthly-report - Generate NIAID monthly report data for task completionstatus

=head1 SYNOPSIS

    p3x-monthly-report YYYY-MM > report.txt

=head1 DESCRIPTION

Generate summary data for the given month.

We assume the data is live in the Task tables in the database 
and not archived in the historical data. If we wish to look back to the historical 
data this script will need to be modified to do so.

=cut

use Data::Dumper;
use strict;
use FileHandle;
use Bio::KBase::AppService::SchedulerDB;
use List::MoreUtils qw(first_index);
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o YYYY-MM",
				    ["output|o=s" => "Write output to this file instead of stdout"],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit if $opt->help;
die($usage->text) unless @ARGV == 1;

my $month_str = shift;

my($year, $month) = $month_str =~ m!^(\d{4})[/-](\d{1,2})$!;
if (!$year || !$month || $year !~ /^20/ || $month < 0 || $month > 12)
{
    die "Invalid month specfiication '$month_str'\n";
}

my $end_year = $year;
my $end_month = $month + 1;
$end_year++ if $end_month > 12;

my $start = sprintf("%04d-%02d-01", $year, $month);
my $end = sprintf("%04d-%02d-01", $end_year, $end_month);

my $start_ts = "$start:00:00:00";
my $end_ts = "$end:00:00:00";

my $db = Bio::KBase::AppService::SchedulerDB->new();

my $dbh = $db->dbh;

my %app_values;

my $include_staff = 1;

my $out_fh = \*STDOUT;
if ($opt->output)
{
    $out_fh = FileHandle->new($opt->output, "w");
    $out_fh or die "Cannot open " . $opt->output . ": $!";
}

print $out_fh "Service report for the period $start - $end\n";
print $out_fh "\n";
#
# Determine number of unique users submitting jobs.
#
my $res = $dbh->selectcol_arrayref(qq(SELECT COUNT(DISTINCT owner)
				      FROM Task
				      WHERE submit_time >= ? and submit_time < ?),
				   undef, $start_ts, $end_ts);
my $distinct_users = $res->[0];
print $out_fh "Distinct users submitting jobs:\t$distinct_users\n";
print $out_fh "\n";


#
# Pull time info for completed runs
#

my $staff_check = $include_staff ? "" : "AND is_collaborator = 0 AND is_staff = 0";

my $data = $dbh->selectall_hashref(qq(SELECT application_id,
				     ROUND(AVG(TIMESTAMPDIFF(SECOND, start_time ,finish_time)))  AS avg,
				     MAX(TIMESTAMPDIFF(SECOND, start_time ,finish_time)) AS max,
				     MIN(TIMESTAMPDIFF(SECOND, start_time ,finish_time)) AS min,
				     ROUND(STD(TIMESTAMPDIFF(SECOND, start_time ,finish_time))) AS std,

				     ROUND(AVG(TIMESTAMPDIFF(SECOND, submit_time, start_time)))  AS wait_avg,
				     MAX(TIMESTAMPDIFF(SECOND, submit_time, start_time)) AS wait_max,
				     MIN(TIMESTAMPDIFF(SECOND, submit_time, start_time)) AS wait_min,
				     ROUND(STD(TIMESTAMPDIFF(SECOND, start_time ,finish_time))) AS wait_std,

				     COUNT(TIMESTAMPDIFF(SECOND, start_time ,finish_time)) AS completed
				     FROM Task LEFT OUTER JOIN ServiceUser on Task.owner = ServiceUser.id
				     WHERE state_code = 'C' AND application_id NOT IN ('Date', 'Sleep') AND
				     submit_time >= ? AND
				      submit_time < ? 
				     $staff_check
				     GROUP BY application_id), 'application_id', undef, $start, $end);

#
# Pull total and failed counts.
#

my $total = $dbh->selectall_hashref(qq(SELECT application_id,
				       COUNT(Task.id) as total
				       FROM Task LEFT OUTER JOIN ServiceUser on Task.owner = ServiceUser.id
				       WHERE application_id NOT IN ('Date', 'Sleep') AND
				       state_code IN ('C', 'F') AND
				       submit_time >= ? AND
				       submit_time < ?
				       $staff_check
				       GROUP BY application_id), 'application_id', undef, $start, $end);

my $failed = $dbh->selectall_hashref(qq(SELECT application_id,
					COUNT(Task.id) as failed
					FROM Task LEFT OUTER JOIN ServiceUser on Task.owner = ServiceUser.id
					WHERE application_id NOT IN ('Date', 'Sleep') AND
					state_code = 'F' AND 
					submit_time >= ? AND
					submit_time < ?
					$staff_check
					GROUP BY application_id), 'application_id', undef, $start, $end);
while (my($app, $vals) = each %$total)
{
    $data->{$app}->{total} = $vals->{total};
}

while (my($app, $vals) = each %$failed)
{
    $data->{$app}->{failed} = $vals->{failed};
}

while (my($app, $vals) = each %$data)
{
    if ($vals->{total} > 0)
    {
	$vals->{frac_completed} = $vals->{completed} / $vals->{total};
    }
}

my @cols = qw(total completed failed frac_completed min avg max std wait_min wait_avg wait_max wait_std);
print $out_fh join("\t", 'application', @cols), "\n";
	   
for my $app (sort keys %$data)
{
    my $vals = $data->{$app};
    print $out_fh join("\t", $app, @$vals{@cols}), "\n";
}
