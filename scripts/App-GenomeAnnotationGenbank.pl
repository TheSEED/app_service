#
# The Genome Annotation application. Genbank input variation.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::GenomeAnnotationCore;
use Bio::KBase::AppService::AppConfig 'data_api_url';
use Bio::KBase::AuthToken;
use SolrAPI;

use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use File::Slurp;
use File::Temp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run 'run';
use IO::File;

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

my $rc = $script->run(\@ARGV);

exit $rc;

sub process_genome
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $core = Bio::KBase::AppService::GenomeAnnotationCore->new(app => $app,
								 app_def => $app_def,
								 params => $params);

    my $user_id = $core->user_id;

    #
    # Determine workspace paths for our input and output
    #

    my $ws = $app->workspace();

    my($input_path) = $params->{genbank_file};

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    if (!$output_base)
    {
	$output_base = basename($input_path);
    }

    #
    # Read genbank file data
    #

    my $temp = File::Temp->new();

    $ws->copy_files_to_handles(1, $core->token, [[$input_path, $temp]]);
    
    my $genbank_data_fh;
    close($temp);
    open($genbank_data_fh, "<", $temp) or die "Cannot open contig temp $temp: $!";

    #
    # Read first block to see if this is a gzipped file.
    #
    my $block;
    $genbank_data_fh->read($block, 256);
    if ($block =~ /^\037\213/)
    {
	#
	# Gzipped. Close and reopen from gunzip.
	#
	
	close($genbank_data_fh);
	undef $genbank_data_fh;
	open($genbank_data_fh, "-|", "gzip", "-d", "-c", "$temp") or die "Cannot open gzip from $temp: $!";
    }
    else
    {
	$genbank_data_fh->seek(0, 0);
    }
    
    my $gb_data = read_file($genbank_data_fh);
    close($genbank_data_fh);
    
    my $genome = $core->impl->create_genome_from_genbank($gb_data);

    #
    # Add owner field from token
    #
    if ($core->user_id)
    {
	$genome->{owner} = $core->user_id;
    }

    my $result = $core->run_pipeline($genome);

    #
    # TODO fill in metadata?
    $core->write_output($genome, $result, {});

    $core->ctx->stderr(undef);
}
