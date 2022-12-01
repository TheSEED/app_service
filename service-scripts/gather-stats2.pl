
use Data::Dumper;
use strict;
use Bio::KBase::AppService::SchedulerDB;
use List::MoreUtils qw(first_index);
use Getopt::Long::Descriptive;
use DBI;

my($opt, $usage) = describe_options("%c %o",
				    ["by-user", "Summarize by distinct user"],
				    ["output|o=s", "Write output here"],
				    ["test", "Use test database"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 0;

my $out_fh;
if ($opt->output)
{
    open($out_fh, ">", $opt->output) or die "Cannot write output " . $opt->output . ": $!";
}
else
{
    $out_fh = \*STDOUT;
}
				    

my $db = Bio::KBase::AppService::SchedulerDB->new();

if ($opt->test)
{
    my $dbh =  $db->{dbh} = DBI->connect("dbi:mysql:AppTest;host=cedar.mcs.anl.gov", "olson", undef,
				     { AutoCommit => 1, RaiseError => 1 });
    $dbh or die "Cannot connect to database: " . $DBI::errstr;
    $dbh->do(qq(SET time_zone = "+00:00"));
}

my $apps = $db->dbh->selectcol_arrayref(qq(SELECT DISTINCT a.id, a.display_order
					   FROM Application  a JOIN AllTasks t ON a.id = t.application_id
					   WHERE t.state_code= 'C' AND display_order < 999
					   UNION
					   SELECT DISTINCT a.id, a.display_order
					   FROM Application  a JOIN AllTasks t ON a.id = t.application_id
					   WHERE t.state_code= 'C' AND display_order < 999
					   ORDER BY display_order));

my @with_collab = qw(GenomeAnnotation);
for my $e (@with_collab)
{
    my $i = first_index { $_ eq $e } @$apps;
    splice(@$apps, $i+1, 0, "$e-collab");
}

my %app_index;
for (my $i = 0; $i < @$apps; $i++)
{
    $app_index{$apps->[$i]} = $i;
}

my $field = $opt->by_user ? 'user_count' : 'job_count';
my $tbl = $opt->by_user ? 'BySiteStatsGatherUser' : 'BySiteStatsGather';

my $res = $db->dbh->selectall_arrayref(qq(SELECT month, year, application_id, site, $field FROM $tbl));

my %matrix;
my %seen;
my @order;
for my $ent (@$res)
{
    my($month, $year, $app, $site, $count) = @$ent;
    my $key = "$month/1/$year";
    push(@order, $key) unless $seen{$key}++;
    $matrix{$key}->{$site}->[$app_index{$app}] = $count;
}

#print $out_fh join("\t", "", map { ("PATRIC $_", "BV-BRC $_") } @$apps), "\n";

	    
for my $site ('PATRIC', 'BV-BRC')
{
    print "Per-site data for $site\n";
    print $out_fh join("\t", "", @$apps), "\n";
	
    for my $key (@order)
    {
	my $dat = $matrix{$key}->{$site};
	next unless $dat;
	print $out_fh join("\t", $key, @$dat), "\n";
    }
    print "\n\n";
}



