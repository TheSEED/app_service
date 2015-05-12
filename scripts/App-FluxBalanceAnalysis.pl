#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;
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

my $script = Bio::KBase::AppService::AppScript->new(\&flux_balance_analysis);

my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new();
$script->{workspace_url} = $helper->workspace_url();
$script->{donot_create_result_folder} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

sub flux_balance_analysis
{
    my($app, $app_def, $raw_params, $params) = @_;
	print "Flux balance analysis ", Dumper($app_def, $raw_params, $params);
	$params = $helper->validate_args($params,["model"],{
		media => "/chenry/public/modelsupport/media/Complete",
		fva => 0,
		predict_essentiality => 0,
		minimizeflux => 0,
		findminmedia => 0,
		allreversible => 0,
		thermo_const_type => "None",
		media_supplement => [],
		geneko => [],
		rxnko => [],
		objective_fraction => 1,
		custom_bounds => [],
		objective => [["biomassflux","bio1",1]],
		custom_constraints => [],
		uptake_limits => [],
	});
	if (defined($params->{adminmode}) && $params->{adminmode} == 1) {
    	$helper->admin_mode($params->{adminmode});
    }
    my $model = $helper->get_model($params->{model});
    $params->{model} = $model->_reference();
    
    #Setting output path based on model and then creating results folder
    $params->{output_path} = $model->wsmeta()->[2]."fba";
    $script->create_result_folder();
    
    my $fba = $helper->build_fba_object($model,$params);
    my $objective = $fba->runFBA();
    if (!defined($objective)) {
    	$helper->error("FBA failed with no solution returned! See ".$fba->jobnode());
    }
    $helper->save_object($app->result_folder()."/".$params->{output_file}.".fba",$fba,"fba",{
    	objective => $objective,
    	media => $params->{media}
    });
}
