#
# App wrapper for jobs forwarded from RAST for RASTtk processing.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::GenomeAnnotationCore;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name seedtk);
use IPC::Run;
use SolrAPI;
use DBI;

use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use File::Temp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run;
use IO::File;
use Module::Metadata;
use GenomeTypeObject;

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome, \&preflight);

my $rc = $script->run(\@ARGV);

exit $rc;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    #
    # Do some sanity checking on params.
    #
    # Both recipe and workflow may not be specified.
    #
    if ($params->{workflow} && $params->{recipe})
    {
	die "Both a workflow document and a recipe may not be supplied to an annotation request";
    }

    #
    # Ensure the contigs are valid, and look up their size.
    #

    my $gto = $params->{genome_object};
    $gto or die "Genome object must be specified\n";

    my $res = $app->workspace->stat($gto);
    $res->size > 0 or die "Genome object $gto not found\n";

    my $time = 7200;

    #
    # Request 8 cpus for some of the fatter bits of the compute.
    #
    return {
	cpu => 8,
	memory => "8G",
	runtime => int($time),
	storage => 0,
    };
}

sub process_genome
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $json = JSON::XS->new->pretty(1)->canonical(1);

    #
    # Do some sanity checking on params.
    #
    # Both recipe and workflow may not be specified.
    #
    if ($params->{workflow} && $params->{recipe})
    {
	die "Both a workflow document and a recipe may not be supplied to an annotation request";
    }

    my $core = Bio::KBase::AppService::GenomeAnnotationCore->new(app => $app,
								 app_def => $app_def,
								 params => $params);

    my $user_id = $core->user_id;

    my $ws = $app->workspace();

    my($input_path) = $params->{genome_object};
    my $genome_text = $ws->download_file_to_string($input_path, $core->token);
    my $genome = $core->json->decode($genome_text);

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $core->ctx;
    my $result;

    my $override;
    if (my $ref = $params->{reference_genome_id})
    {
	$override = {
	    evaluate_genome => {
		evaluate_genome_parameters => { reference_genome_id => $ref },
	    }
	};
    }
	
    $result = $core->run_pipeline($genome, $params->{workflow}, $params->{recipe}, $override);

    #
    # We don't use the core write_output here because all we need is the
    # genome object to be written; RAST will perform the rest of the export work for itself.
    #

    $ws->save_data_to_file($core->json->encode($result),
		       {
			   rast_genome_id => $result->{id},
		       },
			   "$output_folder/$output_base", "genome", 1, 1, $core->token);

    $core->ctx->stderr(undef);
}
