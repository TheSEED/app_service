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

use Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl;
use Bio::KBase::GenomeAnnotation::Service;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

my $rc = $script->run(\@ARGV);

exit $rc;

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
    my $token = Bio::KBase::AuthToken->new(ignore_authrc => ($ENV{KB_INTERACTIVE} ? 0 : 1));
    my @username_meta;
    if ($token->validate())
    {
	$ctx->authenticated(1);
	$ctx->user_id($token->user_id);
	$ctx->token($token->token);
	@username_meta = (owner => $token->user_id);
    }
    else
    {
	warn "Token did not validate\n" . Dumper($token);
	
    }

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $ctx;
    my $stderr = Bio::KBase::GenomeAnnotation::ServiceStderrWrapper->new($ctx, $get_time);
    $ctx->stderr($stderr);

    my $impl = Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl->new();

    if (exists($raw_params->{tax_id}) && !exists($params->{taxonomy_id}))
    {
	print STDERR "Fixup incorrect taxid in parameters\n";
	$params->{taxonomy_id} = $raw_params->{tax_id};
    }

    my $meta = {
	scientific_name => $params->{scientific_name},
	genetic_code => $params->{code},
	domain => $params->{domain},
	($params->{taxonomy_id} ? (ncbi_taxonomy_id => $params->{taxonomy_id}) : ()),
	@username_meta,
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

    my @stages = (
	      { name => 'call_features_rRNA_SEED' },
	      { name => 'call_features_tRNA_trnascan' },
	      { name => 'call_features_repeat_region_SEED',
		                        repeat_region_SEED_parameters => { } },
	      { name => 'call_selenoproteins' },
	      { name => 'call_pyrrolysoproteins' },
	      { name => 'call_features_strep_suis_repeat',
		                    condition => '$genome->{scientific_name} =~ /^Streptococcus\s/' },
	      { name => 'call_features_strep_pneumo_repeat',
		                    condition => '$genome->{scientific_name} =~ /^Streptococcus\s/' },
	      { name => 'call_features_crispr', failure_is_not_fatal => 1 },
	      { name => 'call_features_CDS_prodigal' },
	      { name => 'call_features_CDS_glimmer3', glimmer3_parameters => {} },
	      { name => 'annotate_proteins_kmer_v2', kmer_v2_parameters => {} },
	      { name => 'annotate_proteins_kmer_v1', kmer_v1_parameters => { annotate_hypothetical_only => 1 } },
	      { name => 'annotate_proteins_similarity', similarity_parameters => { annotate_hypothetical_only => 1 } },
	      { name => 'resolve_overlapping_features', resolve_overlapping_features_parameters => {} },
	      { name => 'renumber_features' },
	      { name => 'annotate_special_proteins' },
	      { name => 'annotate_families_figfam_v1' },
	      { name => 'find_close_neighbors', failure_is_not_fatal => 1 },
		  # { name => 'call_features_prophage_phispy' },
		 );
    $workflow = { stages => \@stages };
    
    my $result = $impl->run_pipeline($genome, $workflow);

    my $tmp_genome = File::Temp->new;
    print $tmp_genome $json->encode($result);
    close($tmp_genome);

    $ws->save_file_to_file("$tmp_genome", $meta, "$output_folder/$output_base.genome", 'genome', 
			   1, 1, $token);

    #
    # Map export format to the file type.
    my %formats = (genbank => ['genbank_file', "$output_base.gb" ],
		   genbank_merged => ['genbank_file', "$output_base.merged.gb"],
		   spreadsheet_xls => ['string', "$output_base.xls"],
		   spreadsheet_txt => ['string', "$output_base.txt"],
		   seed_dir => ['string',"$output_base.tar.gz"],
		   feature_data => ['feature_table', "$output_base.features.txt"],
		   protein_fasta => ['feature_protein_fasta', "$output_base.feature_protein.fasta"],
		   contig_fasta => ['contigs', "$output_base.contigs.fasta"],
		   feature_dna => ['feature_dna_fasta', "$output_base.feature_dna.fasta"],
		   gff => ['gff', "$output_base.gff"],
		   embl => ['embl', "$output_base.embl"],
		   );

    while (my($format, $info) = each %formats)
    {
	my($file_format, $filename) = @$info;

	#
	# Invoke rast_export_genome explicitly (that is what export_genome does anyway)
	# to have complete control.
	#

	my $tmp_out = File::Temp->new();
	close($tmp_out);

	my $rc = system("rast_export_genome",
			"-i", "$tmp_genome",
			"-o", "$tmp_out",
			"--with-headings",
			$format);
	if ($rc == 0)
	{
	    my $len = -s "$tmp_out";

	    my $file = "$output_folder/$filename";
	    print "Save $len to $file\n";

	    $ws->save_file_to_file("$tmp_out", $meta, $file, $file_format, 1, 1, $token);
	}
	else
	{
	    warn "Error exporting $format\n";
	}
    }

    $ctx->stderr(undef);
    undef $stderr;
}
