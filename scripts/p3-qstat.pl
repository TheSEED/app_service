
=head1 Show PATRIC job queue

    p3-qstat

Use the PATRIC Application Service to show the status of the user's jobs.

=head1 Usage synopsis

    p3-qstat

Show the PATRIC job queue.

=cut

use 5.010;
use strict;
use Getopt::Long::Descriptive;
use Bio::KBase::AppService::Client;
use Try::Tiny;
use Date::Parse;
use POSIX;
use Data::Dumper;

use File::Basename;
use JSON::XS;
use Text::Table::Tiny 'generate_table';

my @valid_status = qw(completed deleted failed queued in-progress);

my $app_service = Bio::KBase::AppService::Client->new();
my($opt, $usage) = describe_options("%c %o [search terms]",
				    ["show-paths|p" => "Show job paths in output"],
				    ["parsable|P" => "Show as parsable tab-delimited text"],
				    ["start-time|s=s" => "Show jobs submitted after the given time"],
				    ["end-time|e=s" => "Show jobs submitted before the given time"],
				    ["status|S=s" => "Limit results to the given job status (@valid_status)"],
				    ["application|a=s" => "Limit results to the given application"],
				    ["n-jobs|n=i" => "Limit to the given number of jobs", { default => 50 } ],
				    ["url=s" => "Override app service URL" ],
		     		    ["help|h", "Show this help message"],
		    );
print($usage->text), exit 0 if $opt->help;

my %params;

if (@ARGV)
{
    $params{search} = join(" ", @ARGV);
}

my $app_service = Bio::KBase::AppService::Client->new($opt->url);

if ($opt->start_time)
{
    my $ts = str2time($opt->start_time);
    if (!$ts)
    {
	die "Cannot parse starting time '" . $opt->start_time . "'\n";
    }
    $params{start_time} = strftime("%Y-%m-%d %H:%M:%SZ", gmtime($ts));
}

if ($opt->end_time)
{
    my $ts = str2time($opt->end_time);
    if (!$ts)
    {
	die "Cannot parse ending time '" . $opt->end_time . "'\n";
    }
    $params{end_time} = strftime("%Y-%m-%d %H:%M:%SZ", gmtime($ts));
}

if ($opt->status)
{
    if (!grep { $_ eq $opt->status } @valid_status)
    {
	die "Invalid job status '" . $opt->status . "'; valid statuss are @valid_status\n";
    }
    $params{status} = $opt->status;
}

my ($ret, $total) = $app_service->enumerate_tasks_filtered(0, $opt->n_jobs, \%params);

my $n = @$ret;
print "Showing $n of $total jobs\n";

my @rows;
my @hdr = ("ID", "Status", "Owner", "Application", "Submit time", "Elapsed time");
push(@hdr, "Path", "File") if $opt->show_paths;

push(@rows, \@hdr);

for my $task (@$ret)
{
    (my $owner = $task->{user_id}) =~ s/\@patricbrc.org$//;

    my $elap = $task->{elapsed_time};
    if ($elap)
    {
	my $h = int($elap / 3600);
	$elap -= $h * 3600;
	my $m = int($elap / 60);
	$elap -= $m * 60;
	$elap = sprintf("%4d:%02d:%02d", $h, $m, $elap);
    }
	
    my @row = ($task->{id}, $task->{status}, $owner, $task->{app},
	       $task->{submit_time}, $elap);
    push(@row, $task->{parameters}->{output_path}, $task->{parameters}->{output_file}) if $opt->show_paths;
    push(@rows, \@row);
    
}

if ($opt->parsable)
{
    say join("\t", @$_) foreach @rows;
}
else
{
    say generate_table(rows => \@rows, header_row => 1);
}
