use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o [task-id ... ]",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;

my @tasks = @ARGV;

my $client = Bio::KBase::AppService::Client->new($opt->url);

for my $task (@tasks)
{
    print "Killing task $task...\n";
    my($killed, $msg) = $client->kill_task($task);
    if ($killed)
    {
	print "Killed. $msg\n";
    }
    else
    {
	print "Not killed: $msg\n";
    }
}

