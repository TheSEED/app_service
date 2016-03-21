#
# Core code for the genome annotation tools.
#

package Bio::KBase::AppService::GenomeAnnotationCore;

use Data::Dumper;
use strict;

use Bio::KBase::AppService::AppConfig 'data_api_url';

use Bio::KBase::GenomeAnnotation::Service;
use Bio::KBase::AuthToken;

use Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl;
use Bio::KBase::GenomeAnnotation::Service;

use SolrAPI;
use IPC::Run 'run';
use IO::File;
use JSON::XS;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(app app_def params svc ctx token impl stderr json));

sub new
{
    my($class, @params) = @_;
    my $self = { @params };
    bless $self, $class;

    $self->json(JSON::XS->new->pretty(1)->allow_nonref);

    $self->init_service();

    return $self;
}

sub init_service
{
    my($self) = @_;

    my $svc = Bio::KBase::GenomeAnnotation::Service->new();
    my $ctx = Bio::KBase::GenomeAnnotation::ServiceContext->new($svc->{loggers}->{userlog},
								client_ip => "localhost");
    $ctx->module($self->app_def->{script});
    $ctx->method($self->app_def->{script});

    my $interactive = $ENV{KB_INTERACTIVE} || (-t STDIN);

    my $token = Bio::KBase::AuthToken->new(ignore_authrc => ($interactive ? 0 : 1));

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
    
    my $stderr = Bio::KBase::GenomeAnnotation::ServiceStderrWrapper->new($ctx, $get_time);
    $ctx->stderr($stderr);

    my $impl = Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl->new();

    $self->ctx($ctx);
    $self->token($token);
    $self->svc($svc);
    $self->impl($impl);
}

sub user_id
{
    my($self) = @_;
    return $self->token ? $self->token->user_id : undef;
}

sub run_pipeline
{
    my($self, $genome) = @_;
    
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
              { name => 'propagate_genbank_feature_metadata',
		    propagate_genbank_feature_metadata_parameters => {} },
	      { name => 'resolve_overlapping_features', resolve_overlapping_features_parameters => {} },
	      { name => 'classify_amr', failure_is_not_fatal => 1 },
	      { name => 'renumber_features' },
	      { name => 'annotate_special_proteins' },
	      { name => 'annotate_families_figfam_v1' },
	      { name => 'annotate_families_patric' },
	      { name => 'annotate_null_to_hypothetical' },
	      { name => 'find_close_neighbors', failure_is_not_fatal => 1 },
	      { name => 'annotate_strain_type_MLST' },
		  # { name => 'call_features_prophage_phispy' },
		 );
    my $workflow = { stages => \@stages };
    
    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $self->ctx;

    print STDERR "Running pipeline on host " . `hostname`. "\n";

    my $result = $self->impl->run_pipeline($genome, $workflow);

    return $result;
}

sub write_output
{
    my($self, $genome, $result, $meta, $genbank_file, $public_flag, $queue_nowait, $no_index) = @_;
    
    my $tmp_genome = File::Temp->new;
    print $tmp_genome $self->json->encode($result);
    close($tmp_genome);

    my $output_base = $self->params->{output_file};
    my $output_folder = $self->app->result_folder();
    my $ws = $self->app->workspace();
    
    $ws->save_file_to_file("$tmp_genome", $meta, "$output_folder/$output_base.genome", 'genome', 
			   1, 1, $self->token);

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

	    $ws->save_file_to_file("$tmp_out", $meta, $file, $file_format, 1, 1, $self->token);
	}
	else
	{
	    warn "Error exporting $format\n";
	}
    }

    #
    # We also export the load files for indexing.
    # Assume here that AWE has placed us into a directory into which we can write.
    #

    if (!$no_index)
    {
	if (write_load_files($ws, $tmp_genome, $genbank_file, $public_flag))
	{
	    my $load_folder = "$output_folder/load_files";
	    
	    $ws->create({overwrite => 1, objects => [[$load_folder, 'folder']]});
	    $self->submit_load_files($ws, $load_folder, $self->token->token, data_api_url, ".", $queue_nowait);
	}
    }
}


sub write_load_files
{
    my($ws, $genome_json_file, $genbank_file, $public_flag) = @_;
    my @cmd = ("rast2solr", "--genomeobj-file", $genome_json_file);
    if ($genbank_file)
    {
	system("ls", "-l", $genbank_file);
	if (!-f $genbank_file)
	{
	    print "Perl thinks no gb file $genbank_file\n";
	}
	push(@cmd, "--genbank-file", $genbank_file);
    }

    if ($public_flag)
    {
	push(@cmd, "--public");
    }

    print STDERR "Processing for indexing: @cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	die "Error $rc creating site load files (@cmd)\n";
    }

    return 1;
}

sub submit_load_files
{
    my($self, $ws, $load_folder, $token, $data_api_url, $dir, $queue_nowait) = @_;

    my $genome_url = $data_api_url . "/indexer/genome";

    my @opts;
    push(@opts, "-H", "Authorization: $token");
    push(@opts, "-H", "Content-Type: multipart/form-data");

    my @files = ([genome => "genome.json"],
		 [genome_feature => "genome_feature.json"],
		 [genome_amr => "genome_amr.json"],
		 [genome_sequence => "genome_sequence.json"],
		 [pathway => "pathway.json"],
		 [sp_gene => "sp_gene.json"],
		 [taxonomy => "taxonomy.json"]);
    
    for my $tup (@files)
    {
	my($key, $file) = @$tup;
	my $path = "$dir/$file";
	if (-f $path)
	{
	    push(@opts, "-F", "$key=\@$path");
	    $ws->save_file_to_file($path, {}, "$load_folder/$file", 'json', 1, 1, $token);
	}
    }

    push(@opts, $genome_url);
    print "@opts\n";
#curl -H "Authorization: AUTHORIZATION_TOKEN_HERE" -H "Content-Type: multipart/form-data" -F "genome=@genome.json" -F "genome_feature=@genome_feature_patric.json" -F "genome_feature=@genome_feature_refseq.json" -F "genome_feature=@genome_feature_brc1.json" -F "genome_sequence=@genome_sequence.json" -F "pathway=@pathway.json" -F "sp_gene=@sp_gene.json"  

    my($stdout, $stderr);
    
    my $ok = run(["curl", @opts], '>', \$stdout);
    if (!$ok)
    {
	warn "Error $? invoking curl @opts\n";
    }

    my $json = JSON->new->allow_nonref;
    my $data = $json->decode($stdout);

    my $queue_id = $data->{id};

    print "Submitted indexing job $queue_id\n";

    return if $queue_nowait;

    my $solr = SolrAPI->new($data_api_url);

    #
    # For now, wait up to an hour for the indexing to complete.
    #
    my $wait_until = time + 3600;

    while (time < $wait_until)
    {
	my $status = $solr->query_rest("/indexer/$queue_id");
	if (ref($status) ne 'HASH')
	{
	    warn "Parse failed for indexer query for $queue_id: " . Dumper($status);
	}
	else
	{
	    my $state = $status->{state};
	    print STDERR "status for $queue_id (state=$state): " . Dumper($status);
	    if ($state ne 'queued')
	    {
		print STDERR "Finishing with state $state\n";
		last;
	    }
	}
	sleep 60;
    }
}


1;
