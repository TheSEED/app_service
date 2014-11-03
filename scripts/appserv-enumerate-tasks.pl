use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if (@ARGV != 0);

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $tasks = $client->enumerate_tasks();

my $mlab = 0;
my $mid = 0;

my $status = $client->query_task_status([ map { $_->{id} } @$tasks ]);

for my $task (@$tasks)
{

    print join("\t", $task->{id}, $task->{app}, $task->{workspace}, $status->{$task->{id}}), "\n";
}

