use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o [task-id ... ]",
				    ["url|u=s", "Service URL"],
				    ["verbose|v", "Show verbose output from service"],
				    ["summary|s", "Show task summary"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;

my @tasks = @ARGV;

my $client = Bio::KBase::AppService::Client->new($opt->url);

if ($opt->summary)
{
    my $status = $client->query_task_summary();

    for my $state (keys %$status)
    {
	print "$state\t$status->{$state}\n";
    }
    exit;

}

my $res = $client->query_tasks(\@tasks);

if ($opt->verbose)
{
    print Dumper($res);
}

for my $task_id (@tasks)
{
    my $task = $res->{$task_id};
    print join("\t", $task->{id}, $task->{app}, $task->{workspace}, $task->{status}, $task->{submit_time}, $task->{completed_time}), "\n";
}

