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

my @time_range =();
#@time_range = ('info.submittime' => { '$gte' => $begin, @end });
my $jobs = $col->query({
    'info.pipeline' => 'AppService',
    'info.name' => 'CodonTree'
    @time_range, @q })->sort({ 'info.user' => 1 })->sort({ 'info.submittime' => 1});

while (my $job = $jobs->next)
{
    my $id = $job->{id};
    my $submit = $job->{info}->{submittime};
    my $start = $job->{info}->{startedtime};
    my $finish = $job->{info}->{completedtime};
    my $user = $job->{info}->{user};
    my $app = $job->{info}->{userattr}->{app_id};
}
