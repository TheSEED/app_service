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

my $helper = Bio::ModelSEED::ProbModelSEED::ProbModelSEEDHelper->new({
	app => $script,
	token => $script->token()->token(),
	username => $script->token()->user_id(),
	method => "GapfillModel",
	run_as_app => 1
});
$helper->load_from_config();
$script->{workspace_url} = $helper->workspace_url();
$script->{donot_create_result_folder} = 1;

my $rc = $script->run(\@ARGV);

exit $rc;

sub gapfill_model
{
    my($app, $app_def, $raw_params, $params) = @_;
	print "Gapfill model ", Dumper($app_def, $raw_params, $params);
	$helper->GapfillModel($params);
}
