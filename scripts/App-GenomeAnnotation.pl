#
# The Genome Annotation application.
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

    if (exists($raw_params->{tax_id}) && !exists($params->{taxonomy_id}))
    {
	print STDERR "Fixup incorrect taxid in parameters\n";
	$params->{taxonomy_id} = $raw_params->{tax_id};
    }

    my $user_id = $core->user_id;

    #
    # Construct genome object metadata and create a new genome object.
    #

    my $meta = {
	scientific_name => $params->{scientific_name},
	genetic_code => $params->{code},
	domain => $params->{domain},
	($params->{taxonomy_id} ? (ncbi_taxonomy_id => $params->{taxonomy_id}) : ()),
	($user_id ? (owner => $user_id) : ()),

    };
    my $genome = $core->impl->create_genome($meta);

    #
    # Determine workspace paths for our input and output
    #

    my $ws = $app->workspace();

    my($input_path) = $params->{contigs};

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    if (!$output_base)
    {
	$output_base = basename($input_path);
    }

    #
    # Read contig data
    #

    my $temp = File::Temp->new();

    $ws->copy_files_to_handles(1, $core->token, [[$input_path, $temp]]);
    
    my $contig_data_fh;
    close($temp);
    open($contig_data_fh, "<", $temp) or die "Cannot open contig temp $temp: $!";

    #
    # Read first block to see if this is a gzipped file.
    #
    my $block;
    $contig_data_fh->read($block, 256);
    if ($block =~ /^\037\213/)
    {
	#
	# Gzipped. Close and reopen from gunzip.
	#
	
	close($contig_data_fh);
	undef $contig_data_fh;
	open($contig_data_fh, "-|", "gzip", "-d", "-c", "$temp") or die "Cannot open gzip from $temp: $!";
    }
    else
    {
	$contig_data_fh->seek(0, 0);
    }
    
    my $n = 0;
    while (my($id, $def, $seq) = gjoseqlib::read_next_fasta_seq($contig_data_fh))
    {
	$core->impl->add_contigs($genome, [{ id => $id, dna => $seq }]);
	$n++;
    }
    close(FH);

    if ($n == 0)
    {
	die "No contigs loaded from $temp $input_path\n";
    }

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $core->ctx;
    my $result = $core->run_pipeline($genome);

    $core->write_output($genome, $result, {}, undef, $parms->{public} ? 1 : 0, $params->{queue_nowait} ? 1 : 0);

    $core->ctx->stderr(undef);
}
