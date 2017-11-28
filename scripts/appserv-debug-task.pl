use Bio::KBase::AppService::Client;
use Bio::KBase::AppService::Shock;
use Bio::KBase::AppService::Awe;
use Bio::KBase::AppService::AweEvents;
use Bio::KBase::AuthToken;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

my($opt, $usage) = describe_options("%c %o task-id",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if (@ARGV != 1);

my $token = Bio::KBase::AuthToken->new;


#
# TODO get this from configs
#
my $awe_server = "http://walnut.mcs.anl.gov:7080";
my $awe_root = "/disks/awe";
my $awe_logs = "$awe_root/logs";

my $json = JSON::XS->new->pretty(1);

my $shock = Bio::KBase::AppService::Shock->new(undef, $token->token);
my $awe = Bio::KBase::AppService::Awe->new($awe_server, $token->token);

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $task_id = shift;

my @tasks = ($task_id);

my $res = $client->query_tasks(\@tasks);

my $task_info = $res->{$task_id};

print Dumper($task_info);

eval {
my $stderr_node = $shock->get_node($task_info->{stderr_shock_node});
print "Stderr: " . $json->encode($stderr_node);
print '-' x 40 . "\n";

my $stdout_node = $shock->get_node($task_info->{stdout_shock_node});
print "Stdout: " . $json->encode($stdout_node);
print '-' x 40 . "\n";

my $awe_job = $awe->job($task_id);
print "AWE job: " . $json->encode($awe_job);
print '-' x 40 . "\n";
};
#
# Find the relevant events.
#

my @work_ids;

for my $log (<$awe_logs/*/event.log>)
{
    open(E, "<", $log) or warn "Cannot open $log: $!";

    my $printed = 0;
    my $qtask_id = quotemeta($task_id);
    while (<E>)
    {
	if (/$qtask_id/)
	{
	    if (!$printed)
	    {
		print "\n$log\n";
		$printed = 1;
	    }
	    my($date, $level, $code, $rest) = parse_event($_);
	    my $event_info = $Bio::KBase::AppService::AweEvents::events{$code};
	    my @details = map { my($k,$v) = split(/=/, $_, 2); [$k, $v] } split(/;/, $rest);
	    if ($event_info->[0] eq 'WORK_CHECKOUT')
	    {
		push(@work_ids, map { split(/,/, $_->[1]) } grep { $_->[0] eq 'workids' } @details);
	    }
	    print "$event_info->[0]\t$date\n";
	    print "\t$_\n" foreach map { join("=", @$_) } @details;
	}
    }
}

for my $work_id (@work_ids)
{
    print "Work id $work_id:\n";
    my(@s) = $work_id =~ /^(..)(..)(..)/;
    my $dir = "$awe_root/work/" . join("/", @s) . "/$work_id";
    system("ls -l $dir");
    for my $file (qw(stderr.txt stdout.txt awe_stderr.txt awe_stodut.txt awe_worknotes.txt))
    {
	if (open(F, "<", "$dir/$file"))
	{
	    print "$dir/$file:\n";
	    print "\t$_" foreach <F>;
	    print "\n";
	    close(F);
	}
    }
	 
}

sub parse_event
{
    my ($x) = @_;
    return $x =~ /^\[([^]]+)\]\s+\[([^]]+)\]\s+([A-Z][A-Z]);(.*)/
}
   
