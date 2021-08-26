
use Data::Dumper;
use strict;
use Bio::KBase::AppService::SchedulerDB;
use List::MoreUtils qw(first_index);
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o",
				    ["by-user", "Summarize by distinct user"],
				    ["output|o=s", "Write output here"],
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

my $apps = $db->dbh->selectcol_arrayref(qq(SELECT DISTINCT a.id, a.display_order
					   FROM Application  a JOIN Task t ON a.id = t.application_id
					   WHERE t.state_code= 'C' AND display_order < 999 ORDER BY display_order));

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
my $tbl = $opt->by_user ? 'StatsGatherUser' : 'StatsGather';

my $res = $db->dbh->selectall_arrayref(qq(SELECT month, year, application_id, $field FROM $tbl));

my %matrix;
my %seen;
my @order;
for my $ent (@$res)
{
    my($month, $year, $app, $count) = @$ent;
    my $key = "$month/1/$year";
    push(@order, $key) unless $seen{$key}++;
    $matrix{$key}->[$app_index{$app}] = $count;
}

print $out_fh join("\t", "", @$apps), "\n";

for my $key (@order)
{
    print $out_fh join("\t", $key, @{$matrix{$key}}), "\n";
}

