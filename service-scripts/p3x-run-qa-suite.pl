#
# Run the entire QA test suite.
#
# We tag all of the runs with a date stamp.
#
# This run is always run using the scheduler.
#
# We emit / save a tab delimited file with the following columns:
#
# Test tag
# Container-id
# App name
# Task ID
# Input filename
# Output filesystem folder
# Output workspace file
# Output workspace folder
#
# The following additional fields will be filled in by task checking software:
#
# Task exit status
# QA success
#

use strict;
use POSIX;
use Data::Dumper;
use Getopt::Long::Descriptive;
use IPC::Run qw(run);
use File::Temp;
use File::Basename;
use File::Slurp;
use JSON::XS;
use POSIX;

my($opt, $usage) = describe_options("%c %o status-file",
				    ["container|c=s" => "Container id to run with"],
				    ["reservation=s" => "Use this reservation for job submission"],
				    ["qa-dir=s" => "Base dir for QA tests", { default => "/vol/patric3/QA/applications" }],
				    ['app=s@' => "Run tests only for this app name"],
				    ['test=s@' => "Run this test"],
				    ["out|o=s" => "Use this workspace path as the output base",
				 { default => '/olson@patricbrc.org/PATRIC-QA/applications' }],
				    ["help|h" => "Show this help message"],
				   );
$usage->die() if @ARGV != 1;
print($usage->text), exit 0 if $opt->help;

my $status_file = shift;
open(STAT, ">", $status_file) or die "Cannot write $status_file: $!";

my $tag = strftime("QA-%Y-%m-%d-%H-%M", localtime);

#
# Enumerate the folders with test subdirectories.
#

my %tests_wanted;
if ($opt->test)
{
    for my $t (@{$opt->test})
    {
	if ($t =~ m,([^/]+)$,)
	{
	    my $tst = $1;
	    $tst =~ s/\.json$//;
	    $tests_wanted{"$tst.json"}++;
	}
    }
}

for my $tfolder (sort { $a cmp $b } glob($opt->qa_dir . "/*/tests"))
{
    my($app) = $tfolder =~ m,/App-([^/]+)/tests,;
    if ($app && $opt->app && ! grep { $app eq $_ } @{$opt->app})
    {
	print "Skipping $tfolder\n";
	next;
    }
    my @tests = sort { $a cmp $b } glob("$tfolder/*.json");

    my @container = ("--container", $opt->container) if $opt->container;

    for my $test (@tests)
    {
	if ($opt->test)
	{
	    next unless $tests_wanted{basename($test)};
	}

	my $temp = File::Temp->new;
	close($temp);
	my @cmd = ("p3x-run-qa",
		   "--submit",
		   ($opt->reservation ? ('--reservation', $opt->reservation) : ()),
		   "--user-metadata", $tag,
		   @container,
		   "--meta-out", "$temp",
		   $test);
	
	print "@cmd\n";
	my $ok = run(\@cmd,
		     init => sub { chdir($tfolder); });
	my @rest;
	if (!$ok)
	{
	    warn "Error running @cmd: $?\n";
	}
	my $meta = decode_json(scalar read_file("$temp"));
	print STAT join("\t",
			$tag,
			$opt->container,
			$meta->{app},
			$meta->{task_id},
			$test,
			$meta->{fs_dir},
			$meta->{output_file},
			$meta->{output_path},
			$meta->{exitcode},
			'',
			'',
			$meta->{hostname}
		       ), "\n";
    }
}
close(STAT);
