#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use strict;
use Data::Dumper;

use Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

my $script = Bio::KBase::AppService::AppScript->new(\&run_probmodelseed_job);
my $config = Bio::KBase::ObjectAPI::utilities::load_config({service => "ProbModelSEED"});
my $targets = [split(/;/,$config->{cache_targets})];
my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new({
	token => $script->token()->token(),
	username => $script->token()->user_id(),
	fbajobcache => $config->{fbajobcache},
	fbajobdir => $config->{fbajobdir},
	mfatoolkitbin => $config->{mfatoolkitbin},
	logfile => $config->{logfile},
	data_api_url => $config->{data_api_url},
	file_cache => undef,
    cache_targets => $targets,
	"workspace-url" => $config->{"workspace-url"},
	"shock-url" => $config->{"shock_url"},
	method => "ModelReconstruction",
});
$script->{workspace_url} = $config->{"workspace-url"};
$script->{donot_create_result_folder} = 1;
$script->{donot_create_job_result} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

sub run_probmodelseed_job
{
    my($app, $app_def, $raw_params, $params) = @_;
    print "Running job: ", Dumper($app_def, $raw_params, $params);
	my $command = $params->{command};
	my $args = Bio::KBase::ObjectAPI::utilities::FROMJSON($params->{arguments});
	$helper->app_harness($command,$args);
}
