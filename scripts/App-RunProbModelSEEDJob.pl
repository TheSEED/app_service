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
$config->{token} = $script->token()->token();
$config->{username} = $script->token()->user_id();
$config->{cache_targets} = [split(/;/,$config->{cache_targets})];
$config->{method} = "ModelReconstruction";
my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new($config);
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
	my $args = $params->{arguments};
	if (!ref($args)) {
		$args = Bio::KBase::ObjectAPI::utilities::FROMJSON($args);
	}
	$helper->app_harness($command,$args);
}
