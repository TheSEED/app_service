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

my $script = Bio::KBase::AppService::AppScript->new(\&reconstruct_model);

my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new();
$script->{workspace_url} = $helper->workspace_url();

my $rc = $script->run(\@ARGV);

exit $rc;

sub reconstruct_model
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Reconstructing model ", Dumper($app_def, $raw_params, $params);

    my $json = JSON::XS->new->pretty(1);
    
    my $input = {
    	app => $app
    };
    if (defined($params->{adminmode})) {
    	$input->{adminmode} = $params->{adminmode}
    }
    
    my $genome;
    if (defined($params->{reference_genome})) {
    	$genome = $helper->retreive_reference_genome($params->{reference_genome});
    } else {
    	$genome = $helper->get_object($params->{genome},"genome");
    }
    
    if (!defined($genome)) {
    	$helper->error("Genome retrieval failed!");
    }

    my $template;
    if (!defined($params->{templatemodel})) {
    	if ($genome->domain() eq "Plant" || $genome->taxonomy() =~ /viridiplantae/i) {
    		$template = $helper->get_object("/chenry/public/modelsupport/templates/plant.modeltemplate","modeltemplate");
    	} else {
    		my $classifier_data = $helper->get_object("/chenry/public/modelsupport/classifiers/gramclassifier.string","string");
    		my $class = $helper->classify_genome($classifier_data,$genome);
    		if ($class eq "Gram positive") {
	    		$template = $helper->get_object("/chenry/public/modelsupport/templates/GramPositive.modeltemplate","modeltemplate");
	    	} elsif ($class eq "Gram negative") {
	    		$template = $helper->get_object("/chenry/public/modelsupport/templates/GramNegative.modeltemplate","modeltemplate");
	    	}
    	}
    } else {
    	$template = $helper->get_object($params->{templatemodel},"modeltemplate");
    }
    
    if (!defined($template)) {
    	$helper->error("template retrieval failed!");
    }
    
    my $mdl = $template->buildModel({
	    genome => $genome,
	    modelid => $params->{output_file},
	    fulldb => $params->{fulldb}
	});
    
    $helper->save_object($app->result_folder()."/".$params->{output_file}.".model",$mdl,"model");
    $helper->save_object($app->result_folder()."/fba",undef,"folder");
    $helper->save_object($app->result_folder()."/gapfilling",undef,"folder");
}
