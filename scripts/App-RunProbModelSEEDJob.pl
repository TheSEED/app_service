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
Bio::KBase::ObjectAPI::config::load_config({
	filename => $ENV{KB_DEPLOYMENT_CONFIG},
	service => "ProbModelSEED"
});
Bio::KBase::ObjectAPI::logging::log("App starting! Current configuration parameters loaded:\n".Data::Dumper->Dump([Bio::KBase::ObjectAPI::config::all_params()]));
my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new({
	token => $script->token()->token(),
	username => $script->token()->user_id(),
	method => "RunProbModelSEEDJob",
});
$script->{workspace_url} = Bio::KBase::ObjectAPI::config::workspace_url();
$script->{donot_create_result_folder} = 1;
$script->{donot_create_job_result} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

sub run_probmodelseed_job
{
    my($app, $app_def, $raw_params, $params) = @_;
    print "Running job: ", Dumper($app_def, $raw_params, $params);
	my $command = $params->{command};
	Bio::KBase::ObjectAPI::config::method($command);
	my $args = $params->{arguments};
	if (!ref($args)) {
		$args = Bio::KBase::ObjectAPI::utilities::FROMJSON($args);
	}
	$helper->app_harness($command,$args);
}
