#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;
use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use LWP::UserAgent;
use JSON::XS;

use Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl;
use Bio::KBase::GenomeAnnotation::Service;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

$script->run(\@ARGV);

sub process_genome
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $json = JSON::XS->new->pretty(1);
    my $svc = Bio::KBase::GenomeAnnotation::Service->new();
    
    my $ctx = Bio::KBase::GenomeAnnotation::ServiceContext->new($svc->{loggers}->{userlog},
								client_ip => "localhost");
    $ctx->module("App-GenomeAnnotation");
    $ctx->method("App-GenomeAnnotation");
    my $token = Bio::KBase::AuthToken->new(ignore_authrc => 1);
    if ($token->validate())
    {
	$ctx->authenticated(1);
	$ctx->user_id($token->user_id);
	$ctx->token($token->token);
    }
    else
    {
	warn "Token did not validate\n" . Dumper($token);
	
    }

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $ctx;
    my $stderr = Bio::KBase::GenomeAnnotation::ServiceStderrWrapper->new($ctx, $get_time);
    $ctx->stderr($stderr);

    my $impl = Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl->new();

    my $meta = {
	scientific_name => $params->{scientific_name},
	genetic_code => $params->{code},
	domain => $params->{domain},
	($params->{taxonomy_id} ? (ncbi_taxonomy_id => $params->{taxonomy_id}) : ()),
    };
    my $genome = $impl->create_genome($meta);

    my $ws = $app->workspace();

    my($input_path) = $params->{contigs};

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    if (!$output_base)
    {
	$output_base = basename($input_path);
    }

    my $temp = File::Temp->new();

    $ws->copy_files_to_handles(1, $token, [[$input_path, $temp]]);
    
    my $contig_data_fh;
    close($temp);
    open($contig_data_fh, "<", $temp) or die "Cannot open contig temp $temp: $!";

    my $n = 0;
    while (my($id, $def, $seq) = gjoseqlib::read_next_fasta_seq($contig_data_fh))
    {
	$impl->add_contigs($genome, [{ id => $id, dna => $seq }]);
	$n++;
    }
    close(FH);

    if ($n == 0)
    {
	die "No contigs loaded from $temp $input_path\n";
    }

    my $workflow = $impl->default_workflow();
    my $result = $impl->run_pipeline($genome, $workflow);

    $ws->save_data_to_file($json->encode($result), $meta, "$output_folder/$output_base.genome", 'genome', 
			   1, 1, $token);

    #
    # Map export format to the file type.
    my %formats = (genbank => 'genbank_file',
		   genbank_merged => 'genbank_file',
		   spreadsheet_xls => 'string',
		   spreadsheet_txt => 'string',
		   seed_dir => 'string',
		   feature_data => 'feature_table',
		   protein_fasta => 'feature_protein_fasta',
		   contig_fasta => 'contigs',
		   feature_dna => 'feature_dna_fasta',
		   gff => 'gff',
		   embl => 'embl');

    while (my($format, $file_format) = each %formats)
    {
	my $exp = $impl->export_genome($result, $format, []);
	my $len = length($exp);

	my $file = "$output_folder/$output_base.$format";
	print "Save $len to $file\n";

	$ws->save_data_to_file($exp, $meta, $file, $file_format, 1, 1, $token);
    }

    $ctx->stderr(undef);
    undef $stderr;
}
