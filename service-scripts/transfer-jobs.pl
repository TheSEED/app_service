#
# Gather summary statistics for the app service.
#

use v5.010;
use Bio::P3::DeploymentConfig;
use Data::Dumper;
use strict;
use DateTime;
use DateTime::Format::MySQL;
use MongoDB;
use JSON::XS;
use File::Slurp;

my $json = JSON::XS->new->utf8(0);

my $cfg = Bio::P3::DeploymentConfig->new("AppService");

#print Dumper($cfg);
my $mongo = MongoDB::MongoClient->new(host => $cfg->setting("awe-mongo-host"),
				      port => ($cfg->setting("awe-mongo-port") // 27017),
				      db_name => $cfg->setting("awe-mongo-db"),
				      (defined($cfg->setting("awe-mongo-user")) ? (username => $cfg->setting("awe-mongo-user")) : ()),
				      (defined($cfg->setting("awe-mongo-pass")) ? (password => $cfg->setting("awe-mongo-pass")) : ()),
				     );
my $db = $mongo->get_database($cfg->setting("awe-mongo-db"));
my $col = $db->get_collection("Jobs");

my @q = (state => 'completed');
#@q = ();

#my $begin = DateTime->new(year => 2015, month => 10, day => 1)->set_time_zone( 'America/Chicago' );
my $end = DateTime->new(year => 2019, month => 9, day => 15)->set_time_zone( 'America/Chicago' );
my $begin = DateTime->new(year => 2018, month => 9, day => 1)->set_time_zone( 'America/Chicago' );
my @end;
@end = ('$lt' => $end );

my %skip = map { $_ => 1 } qw(PATRIC@patricbrc.org rastuser25@patricbrc.org);

my $jobs = $col->query({
    'info.pipeline' => 'AppService',
    'info.submittime' => { '$gte' => $begin, @end }, @q })->sort({ 'info.submittime' => 1});

my $n;
while (my $job = $jobs->next)
{
    my $id = $job->{id};
    my $submit = $job->{info}->{submittime};
    my $start = $job->{info}->{startedtime};
    my $finish = $job->{info}->{completedtime};
    my $user = $job->{info}->{user};
    my $app = $job->{info}->{userattr}->{app_id};
    next if $app eq 'Sleep' or $app eq 'Date';
    
    next if $skip{$user};

say $id,$submit->time_zone;
die "$submit\n";

    my $elap = $finish->epoch - $start->epoch;

    my $params_t = $job->{info}->{userattr}->{parameters};
    my($out_file, $out_path);
    my $params;
    if ($params_t)
    {
	$params = $json->decode($params_t);
    }
    next unless $params->{output_path};

    my $ex = read_file("/disks/p3/task_status/$id/exitcode", err_mode => 'quiet');
    chomp $ex;
    my $host = read_file("/disks/p3/task_status/$id/hostname", err_mode => 'quiet');
    chomp $host;

    $params->{output_path} =~ s/\t/\\\t/g;
    $params->{output_file} =~ s/\t/\\\t/g;
    $ex ||= 0;
    $host ||= '?';
    $params_t =~ s/\t/\\\t/g;
    $params_t =~ s/\n/\\\n/g;
    print join("\t", $id, $user, 'C', $app,
	       DateTime::Format::MySQL->format_datetime($submit),
	       DateTime::Format::MySQL->format_datetime($start),
	       DateTime::Format::MySQL->format_datetime($finish),
	       $params_t,
	       $params->{output_path}, $params->{output_file},
	       $ex, $host,
	       ),"\n";
}
