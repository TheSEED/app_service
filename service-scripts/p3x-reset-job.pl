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

use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV == 0;

my $db = Bio::KBase::AppService::SchedulerDB->new();

my @task_ids;

foreach (@ARGV)
{
    /^\d+$/ or die "Invalid task id $_\n";
    push(@task_ids, $_);
}

for my $task (@task_ids)
{
    $db->reset_job($task);
}
