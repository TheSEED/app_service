=head1 NAME
    
    p3x-reset - reset a job back to queued state
    
=head1 SYNOPSIS

    p3x-qdel [OPTION] jobid [jobid...]
    
=head1 DESCRIPTION

Resets a job back to be queued state.

=cut

use strict;
use Data::Dumper;
use JSON::XS;
use Bio::KBase::AppService::SchedulerDB;
use Time::Duration::Parse;

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["time|t=s" => "Reset the requested duration"],
				    ["memory|m=s" => "Reset the requested memory"],
				    ["cpu|c=s" => "Reset the requested number of cpus"],
				    ["data-container|D=s" => "Reset the requested data container"],
				    ["container|C=s" => "Reset the requested runtime container"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV == 0;

my $time;
if ($opt->time =~ /^(\d+)-(\S+)$/)
{
    my $days = $1;
    my $ts = $2;
    $time = eval { parse_duration($ts); };
    die "Cannot parse '$ts': $@" unless defined($time);
    $time += $days * 86400;
}
elsif ($opt->time)
{
    $time = eval { parse_duration($opt->time); };
    die "Cannot parse '" . $opt->time . "'" unless defined($time);
}

my $db = Bio::KBase::AppService::SchedulerDB->new();

my @task_ids;

foreach (@ARGV)
{
    if (/^(\d+),?$/)
    {
	push(@task_ids, $1);
    }
    else
    {
	die "Invalid task id $_\n";
    }
}

for my $task (@task_ids)
{
    $db->reset_job($task, {
       ($time ? (time => $time) : ()),
       ($opt->memory ? (memory => $opt->memory) : ()),
       ($opt->cpu ? (cpu => $opt->cpu) : ()),
       ($opt->data_container ? (data_container_id => $opt->data_container) : ()),
       ($opt->container ? (container_id => $opt->container) : ()),
   });
}
