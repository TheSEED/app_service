#
# Replay jobs from a given time period.
#
# Rewrite usernames so as to not clutter users' workspaces.
# Rewrite output to go to a test workspace.
# Only replay jobs with data from public workspaces.
# 
#

use strict;
use Bio::KBase::AppService::AppServiceImpl;
use Bio::KBase::AppService::Client;
use DateTime::Format::DateParse;
use Getopt::Long::Descriptive;
use Data::Traverse qw(traverse);
use JSON::XS;
use Data::Dumper;
use Data::Walk;
use Bio::P3::Workspace::WorkspaceClientExt;

my($opt, $usage) = describe_options("%c %o start-time end-time base-workspace service-url",
				    ["n-jobs|n=i" => "Limit to N jobs", { default => 3 }],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 4;

my $start_str = shift;
my $end_str = shift;
my $base_ws = shift;
my $service_url = shift;

my $app_service = Bio::KBase::AppService::Client->new($service_url);

my $start_time = DateTime::Format::DateParse->parse_datetime($start_str);
my $end_time = DateTime::Format::DateParse->parse_datetime($end_str);

$start_time or die "cannot parse $start_str as a time\n";
$end_time or die "cannot parse $end_str as a time\n";

my $ws = Bio::P3::Workspace::WorkspaceClientExt->new;

print STDERR "$start_time  - $end_time\n";

my %skip_apps = map { $_ => 1 } qw(ComprehensiveGenomeAnalysis
				   GenomeAssembly
				   MetagenomeBinning
				   TaxonomicClassification
				   MetagenomicReadMapping);


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

my $jobs = $col->query({
    'info.pipeline' => 'AppService',
    'info.submittime' => { '$gte' => $start_time, '$lt' => $end_time },
}) -> sort({'info.submittime' => 1});

my $n = 0;
while (my $job = $jobs->next)
{
    my $id = $job->{id};
    my $submit = $job->{info}->{submittime};
    my $start = $job->{info}->{startedtime};
    my $finish = $job->{info}->{completedtime};
    my $user = $job->{info}->{user};
    my $app = $job->{info}->{userattr}->{app_id};
    my $params_str = $job->{info}->{userattr}->{parameters};
    my $params = decode_json($params_str);

    if ($user =~ /^([^@]+)\@patricbrc\.org$/)
    {
	$user = "replay-$1\@patricbrc.org";
    }
    else
    {
	print STDERR "Skipping invalid user $user\n";
	next;
    }
    if ($skip_apps{$app})
    {
	print STDERR "Skipping app $app\n";
	next;
    }
    print STDERR "Map user to $user\n";

    last if ($n++ >= $opt->n_jobs);
	
    my $orig_out = delete $params->{output_path};

    my $bad;
    traverse {
     	if (/ARRAY/)
     	{
     	    $bad ||= check_ws($a, $ws);
     	}
     	elsif (/HASH/)
     	{
	    $bad ||= check_ws($b, $ws);
     	}
    } $params;
    if ($bad)
    {
	print "Skip $id\n";
	next;
    }

    #
    # Job is OK (no references to private data).
    #
    # Set the output to a modified output path based on the original output.
    #

    $params->{output_path} = $base_ws . $orig_out;

    if ($app =~ /^GenomeAnno/)
    {
	$params->{skip_indexing} = 1;
    }
    print Dumper($app, $params);

    my $task = $app_service->start_app2($app, $params, { user_override => $user });
    print Dumper($task);
}

sub check_ws
{
    my($str, $ws) = @_;

    if ($str =~ m,^/,)
    {
	my $perms = eval { $ws->list_permissions({objects => [$str], adminmode => 1}) };
	return 1 if !defined($perms);
	my($glob) = grep { $_->[0] eq 'global_permission'} @{$perms->{$str}};
	return $glob->[1] eq 'n';
    }
}
   
sub xform_ws
{
    my($str, $base) = @_;

    if ($str =~ m,^/([a-z0-9_.-]+)(@[a-z0-9_.]+)?/(.*)$,)
    {
	my $new = "$base/$1$2/$3";
	print "$str =>$ new\n";
	return $new;
    }
    else
    {
	return $str;
    }
}
   
