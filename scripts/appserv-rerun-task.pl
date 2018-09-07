use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o task-id",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV != 1;

my $task = shift;

my $client = Bio::KBase::AppService::Client->new($opt->url);

print "Restarting task $task...\n";
my $new_task = $client->rerun_task($task);
if ($new_task)
{
    print "Task rerun started; new task id is $new_task\n";
}
else
{
    print "Error rerunning task\n";
}

