
use Data::Dumper;
use strict;
use Bio::KBase::AppService::SchedulerDB;
use List::MoreUtils qw(first_index);

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

my $res = $db->dbh->selectall_arrayref(qq(SELECT month, year, application_id, job_count FROM StatsGather));

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

print join("\t", "", @$apps), "\n";

for my $key (@order)
{
    print join("\t", $key, @{$matrix{$key}}), "\n";
}

