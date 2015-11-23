#
# Gather summary statistics for the app service.
#

use Bio::KBase::AuthToken;
use Bio::KBase::AppService::Awe;
use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::DeploymentConfig;
use Data::Dumper;
use strict;
use DateTime;

my $impl = Bio::KBase::AppService::AppServiceImpl->new();

my $mongo = MongoDB::MongoClient->new(host => $impl->{awe_mongo_host}, port => $impl->{awe_mongo_port});
my $db = $mongo->get_database($impl->{awe_mongo_db});
my $col = $db->get_collection("Jobs");

my @q = (state => 'completed');
#@q = ();

my $begin = DateTime->new(year => 2015, month => 3, day => 1)->set_time_zone( 'America/Chicago' );

my $jobs = $col->query({
    'info.pipeline' => 'AppService',
    'info.submittime' => { '$gte' => $begin }, @q })->sort({ 'info.user' => 1 })->sort({ 'info.submittime' => 1});

my %total;
my $total_jobs = 0;
my %total_by_app;
my %user;
while (my $job = $jobs->next)
{
    my $id = $job->{id};
    my $submit = $job->{info}->{submittime};
    my $start = $job->{info}->{startedtime};
    my $finish = $job->{info}->{completedtime};
    my $user = $job->{info}->{user};
    my $app = $job->{info}->{userattr}->{app_id};
    next if $app eq 'Sleep' or $app eq 'Date';
    my $colkey = $user;

    my $elap = $finish->epoch - $start->epoch;
    $elap /= 60;

#    print STDERR join("\t", $id, $start, $finish, $elap, $app), "\n";

    $user{$colkey}++;

    # my $dkey = sprintf("%d-%02d", $submit->week_year, $submit->week_number);
    $submit->truncate(to => 'week');
    my $dkey = $submit->date;
    $total{$dkey}->{$colkey}++;
    # $total{$dkey}->{$colkey} += $elap;

    $total_by_app{$app}++;
}

my @applist = qw(GenomeAssembly GenomeAnnotation GenomeComparison ModelReconstruction GapfillModel RNASeq DifferentialExpression);
for my $app (@applist)
{
    print "$app\t$total_by_app{$app}\n";
    delete $total_by_app{$app};
}
die Dumper(\%total_by_app);
exit;

my @users = sort { $a cmp $b } keys %user;

# my @users = qw(GenomeAssembly GenomeAnnotation GenomeComparison ModelReconstruction GapfillModel RNASeq DifferentialExpression);

print join("\t", "Week", "Date", @users), "\n";

my $maxusers;
for my $date (sort { $a cmp $b } keys %total)
{
    my $data = $total{$date};
    my @u = sort { $data->{$a} <=>  $data->{$b} }  keys %$data;
    $maxusers = @u if @u > $maxusers;
}

print join("\t", "Week", "Date", map { "User" . $_ } 1..$maxusers), "\n";

my $i = 1;
for my $date (sort { $a cmp $b } keys %total)
{
    my $data = $total{$date};
    my @u = sort { $data->{$a} <=>  $data->{$b} }  keys %$data;
    # my @u = @users;
    print "$i\t$date";
    $i++;
    for my $i (0..$#u)
    {
	print "\t$data->{$u[$i]}";
    }
    print "\n";
}


