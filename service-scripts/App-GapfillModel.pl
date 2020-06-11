#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use File::Temp;
use LWP::UserAgent;
use JSON::XS;

use Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

my $script = Bio::KBase::AppService::AppScript->new(\&gapfill_model, \&preflight_cb);
my $config = Bio::KBase::ObjectAPI::utilities::load_config({service => "ProbModelSEED"});
my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new({
	token => $script->token()->token(),
	username => $script->token()->user_id(),
	fbajobcache => $config->{fbajobcache},
	fbajobdir => $config->{fbajobdir},
	mfatoolkitbin => $config->{mfatoolkitbin},
	logfile => $config->{logfile},
	data_api_url => $config->{data_api_url},
	"workspace-url" => $config->{"workspace-url"},
	"shock-url" => $config->{"shock_url"},
	method => "GapfillModel",
});
$script->{workspace_url} = $config->{"workspace-url"};
$script->{donot_create_result_folder} = 1;
$script->{donot_create_job_result} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

#
# Run preflight to estimate size and duration.
#
sub preflight_cb
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $time = 60 * 60 * 10;

    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => $time,
	storage => 0,
    };
    return $pf;
}

sub gapfill_model
{
    my($app, $app_def, $raw_params, $params) = @_;
	print "Gapfill model ", Dumper($app_def, $raw_params, $params);
	$helper->GapfillModel($params);
}
