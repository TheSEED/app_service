use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o task-id",
				    ["output-path|p=s", "Change output path"],
				    ["output-file|o=s", "Change output file"],
				    ["url|u=s", "Service URL"],
				    ["verbose|v", "Show verbose new-task output"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
die($usage->text) if @ARGV != 1;

my $task = shift;

my $client = Bio::KBase::AppService::Client->new($opt->url);

print "Restarting task $task...\n";

if ($opt->output_path || $opt->output_file)
{
    #
    # For these, pull the task, modify, and resubmit.
    #
    my $tobj = $client->query_tasks([$task]);
    $tobj or die "Cannot find task $task\n";
    $tobj = $tobj->{$task};
    $tobj or die "Cannot find task $task\n";
    my $params = $tobj->{parameters};
    if ($opt->output_path)
    {
	$params->{output_path} = $opt->output_path;
    }
    if ($opt->output_file)
    {
	$params->{output_file} = $opt->output_file;
    }
    print STDERR "Resubmitting with output_path=$params->{output_path} and output_file=$params->{output_file}\n";
    my $new_task = $client->start_app($tobj->{app}, $params, $tobj->{workspace});
    if ($opt->verbose)
    {
	print "New task: " . Dumper($new_task);
    }
    if ($new_task)
    {
	print "Task rerun started; new task id is $new_task->{id}\n";
    }
    else
    {
	print "Error rerunning task\n";
    }

}
else
{
    my $new_task = $client->rerun_task($task);
    
    if ($opt->verbose)
    {
	print "New task: " . Dumper($new_task);
    }
    if ($new_task)
    {
	print "Task rerun started; new task id is $new_task->{id}\n";
    }
    else
    {
	print "Error rerunning task\n";
    }
}
