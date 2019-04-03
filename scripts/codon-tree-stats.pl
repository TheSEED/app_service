#
# Gather summary statistics for the app service.
#

use JSON::XS;
use Bio::KBase::AuthToken;
use Bio::KBase::AppService::Awe;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::DeploymentConfig;
use Data::Dumper;
use strict;
use DateTime;

my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();
my $impl = Bio::KBase::AppService::AppServiceImpl->new();

print STDERR "Connect to $impl->{awe_mongo_host} $impl->{awe_mongo_port}\n";
my $mongo = MongoDB::MongoClient->new(host => $impl->{awe_mongo_host},
				      port => $impl->{awe_mongo_port},
				      db_name => $impl->{awe_mongo_db},
				      (defined($impl->{awe_mongo_user}) ? (username => $impl->{awe_mongo_user}) : ()),
				      (defined($impl->{awe_mongo_pass}) ? (password => $impl->{awe_mongo_pass}) : ()),
				     );
my $db = $mongo->get_database($impl->{awe_mongo_db});
my $col = $db->get_collection("Jobs");

#my $begin = DateTime->new(year => 2015, month => 10, day => 1)->set_time_zone( 'America/Chicago' );
my $end = DateTime->new(year => 2018, month => 4, day => 1)->set_time_zone( 'America/Chicago' );
my $begin = DateTime->new(year => 2013, month => 1, day => 1)->set_time_zone( 'America/Chicago' );
my @end;
@end = ('$lt' => $end );

my @q = (state => 'completed');

my @time_range =();
#@time_range = ('info.submittime' => { '$gte' => $begin, @end });
my $jobs = $col->query({
    'info.pipeline' => 'AppService',
    'info.name' => 'CodonTree',
    @time_range, @q })->sort({ 'info.user' => 1 })->sort({ 'info.submittime' => 1});

my $keys;
while (my $job = $jobs->next)
{
    my $id = $job->{id};
    my $info = $job->{info};
    my $submit = $info->{submittime};
    my $start = $info->{startedtime};
    my $finish = $info->{completedtime};
    my $user = $info->{user};
    my $attr = $info->{userattr};
    my $params = eval { decode_json($attr->{parameters}); };
    my $path = "$params->{output_path}/.$params->{output_file}";
    my $stats_path = "$path/codontree_codontree_analysis.stats";
    my $token = $info->{datatoken};
    my $stats = eval {
	$ws->download_file_to_string($stats_path, undef, { admin => 1 });
    };
    if (!$stats)
    {
	warn "no stats for $stats_path $token\n";
    }
    open(F, "<", \$stats);
    $_ = <F>;
    my @k;
    my @v;
    while (<F>)
    {
	chomp;
	if (/Total\s+job\s+duration\s+(\d+)/)
	{
	    unshift(@k, "Duration");
	    unshift(@v, $1);
	}
	else
	{
	    my($k,$v) = split(/\t/);
	    push(@k, $k);
	    push(@v, $v);
	}
    }
    if (!$keys)
    {
	$keys = ["JobID", "User", @k] unless $keys;
	print join("\t", @$keys), "\n";
    }
    print join("\t", $id, $user, @v), "\n";
}
