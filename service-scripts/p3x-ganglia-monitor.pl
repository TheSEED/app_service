#
# Log current state of both app service and cluster queues for PATRIC.
#
# We log for four classes of apps - assembly, annotation, cga, and other, plus totals.
# We log for queued and in-cluster states.
#
#
# For cluster queues, we log the same app classes, and log queued and running.
# We also monitor totals for P3 total, RAST, and cluster total.
#

use DBI;
use strict;
use Data::Dumper;

my @gmetric = ("/vol/ganglia/bin/gmetric",  "-c", "/vol/ganglia-data/etc/gmond-unicast.conf");


my $host = "cedar.mcs.anl.gov";
my $user = "app_monitor";
my $db = "AppService";
my $port = 3306;
my $pass = "app";

my $dbh = DBI->connect("dbi:mysql:$db;host=$host;port=$port", $user, $pass);

my $res = $dbh->selectall_arrayref(qq(SELECT t.state_code, c.class_name, count(id)
				      FROM Task t LEFT OUTER JOIN ganglia_app_class c
				      ON t.application_id = c.application_id
				      WHERE state_code IN ('S', 'Q')
				      GROUP BY c.class_name, t.state_code));

#
# We grab the scheduler app classes.
#
my $classes = $dbh->selectall_hashref(qq(SELECT application_id, class_name
					 FROM ganglia_app_class), 'application_id');

my %app_names = map {  $_ => 1 } ((map { $_->{class_name} } values %$classes), 'Other');
my @app_names = sort keys %app_names;

#
# Each of the totals here are directly logged.
# We count totals for overall S & Q states.
#
my %map_state = (S => "in_cluster", Q => "queued");

my %total_state;
my %by_app_class;
for my $state (values %map_state)
{
    $total_state{$state} = 0;
    $by_app_class{$_}->{$state} = 0 foreach @app_names;
}

for my $ent (@$res)
{
    my($state, $class, $count) = @$ent;
    $class //= "Other";
    $state = $map_state{$state};
    $total_state{$state} += $count;
    $by_app_class{$class}->{$state} = $count;
}
#die Dumper(\%by_app_class, \%map_state, \@app_names ) if $ENV{DEBUG};
for my $state (values %map_state)
{
    my $name = "app_total_$state";
    glog($name, $total_state{$state});

    for my $app (@app_names)
    {
	my $name = "app_${app}_$state";
	glog($name, $by_app_class{$app}->{$state});
    }
}


#
# Now process queue data
#


#
# Get queue and compute totals by app and state, by user, and overall.
#


my %by_app;
my %by_user;
my %total_by_state;
my $total = 0;

my @slurm_states = qw(pending running configuring);
my %user_map = (p3 => "PATRIC", rastprod => "RAST");

for my $state (@slurm_states)
{
    $total_by_state{$state} = 0;
    for my $app (@app_names)
    {
	$by_app{$app}->{$state} = 0;
    }
    $by_user{$_}->{$state} = 0 foreach values %user_map;
}

open(Q, "-|",
     "/disks/patric-common/slurm/bin/squeue", "-o", "%i\t%k\t%T\t%u", "--noheader");
while (<Q>)
{
    chomp;
    my($id, $app, $state, $user) = split(/\t/);

    my $uclass = $user_map{$user} // "Other";

    $total++;
    $total_by_state{lc($state)}++;
    $by_user{$uclass}->{lc($state)}++;

    if ($user eq 'p3')
    {
	my $class = $classes->{$app}->{class_name} // "Other";
	$by_app{$class}->{lc($state)}++;
    }
}

while (my($class, $hash) = each %by_app)
{
    while (my($state, $count) = each %$hash)
    {
	my $name = "slurm_${class}_${state}";
	glog($name, $count);
    }
}

while (my($user, $hash) = each %by_user)
{
    while (my($state, $count) = each %$hash)
    {
	my $name = "slurm_${user}_${state}";
	glog($name, $count);
    }
}

while (my($state, $count) = each %total_by_state)
{
    my $name = "slurm_${state}";
    glog($name, $count);
}
my $name = "slurm_total";
glog($name, $total);

sub glog
{
    my($name, $value) = @_;
    my @cmd = (@gmetric,
	       "--name", $name,
	       "--value", $value,
	       "--type", "uint32",
	       "--units", "jobs");
    if ($ENV{DEBUG})
    {
	print "@cmd\n";
	return;
     }
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	die "Failed: @cmd\n";
    }
}

__DATA__
olson@holly:~$ squeue -o "%i %k %T" --noheader | sort  -k2,3
488825 CodonTree RUNNING
488861 CodonTree RUNNING
488803 ComprehensiveGenomeAnalysis RUNNING
488867 GenomeAnnotation RUNNING
488778 GenomeAssembly2 RUNNING
488684 Variation RUNNING

olson@holly:~$ squeue -o "%i %k %T" --noheader | sort  -k2,3 | uniq -c -f 1
2 488825 CodonTree RUNNING
1 488892 GenomeAnnotation RUNNING
1 488778 GenomeAssembly2 RUNNING
1 488684 Variation RUNNING

