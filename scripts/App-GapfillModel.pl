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

my $script = Bio::KBase::AppService::AppScript->new(\&gapfill_model);

my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new();
$script->{workspace_url} = $helper->workspace_url();
$script->{donot_create_result_folder} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

sub gapfill_model
{
    my($app, $app_def, $raw_params, $params) = @_;
	print "Gapfill model ", Dumper($app_def, $raw_params, $params);
	$params = $helper->validate_args($params,["model"],{
		media => "/chenry/public/modelsupport/media/Complete",
		probanno => undef,
		alpha => 0,
		allreversible => 0,
		thermo_const_type => "None",
		media_supplement => [],
		geneko => [],
		rxnko => [],
		objective_fraction => 1,
		uptake_limits => [],
		custom_bounds => [],
		objective => [["biomassflux","bio1",1]],
		custom_constraints => [],
		low_expression_theshold => 0.5,
		high_expression_theshold => 0.5,
		target_reactions => [],
		completeGapfill => 0,
		solver => undef,
		omega => 0,
		allowunbalanced => 0,
		blacklistedrxns => [],
		gauranteedrxns => [],
		exp_raw_data => {},
		source_model => undef,
		integrate_solution => 0,
	});
    if (defined($params->{adminmode}) && $params->{adminmode} == 1) {
    	$helper->admin_mode($params->{adminmode});
    }
    my $model = $helper->get_model($params->{model});
    $params->{model} = $model->_reference();
    
    #Setting output path based on model and then creating results folder
    $params->{output_path} = $model->wsmeta()->[2]."gapfilling";
    if (!defined($params->{output_file})) {
	    my $gflist = $helper->workspace_service()->ls({
			paths => [$model->wsmeta()->[2]."gapfilling"],
			excludeDirectories => 1,
			excludeObjects => 0,
			recursive => 1,
			query => {type => "fba"}
		});
		my $index = @{$gflist};
		for (my $i=0; $i < @{$gflist}; $i++) {
			if ($gflist->[$i]->[0] =~ /^gf\.(\d+)$/) {
				if ($1 > $index) {
					$index = $1+1;
				}
			}
		}
		$params->{output_file} = "gf.".$index;
    }
    Bio::KBase::ObjectAPI::utilities::set_global("gapfill name",$params->{output_file});
    $script->create_result_folder();
    
    if (defined($params->{source_model})) {
		$params->{source_model} = $helper->get_model($params->{source_model});
    }
    
    my $fba = $helper->build_fba_object($model,$params);
    $fba->PrepareForGapfilling($params);
    my $objective = $fba->runFBA();
    $fba->parseGapfillingOutput();
    if (!defined($fba->gapfillingSolutions()->[0])) {
		$helper->error("Analysis completed, but no valid solutions found!");
	}
	if (@{$fba->gapfillingSolutions()->[0]->gapfillingSolutionReactions()} == 0) {
		$helper->error("No gapfilling needed on specified condition!");
	}
	my $gfsols = [];
	for (my $i=0; $i < @{$fba->gapfillingSolutions()}; $i++) {
		for (my $j=0; $j < @{$fba->gapfillingSolutions()->[$i]->gapfillingSolutionReactions()}; $j++) {
			$gfsols->[$i]->[$j] = $fba->gapfillingSolutions()->[$i]->gapfillingSolutionReactions()->[$j]->serializeToDB();
		}
	}
	my $solutiondata = Bio::KBase::ObjectAPI::utilities::TOJSON($gfsols);
	$helper->save_object($app->result_folder()."/".$params->{output_file}.".fba",$fba,"fba",{
		integrated_solution => 0,
		solutiondata => $solutiondata,
		integratedindex => 0,
		media => $params->{media},
		integrated => $params->{integrate_solution}
	});
}
