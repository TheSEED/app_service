#!/usr/bin/env perl

###########################################################
#
# rast2QC.pl: 
#
# Script to parse RASTtk genome object, compute genome QC 
# parameters, and add them to the GTO. 
#
###########################################################

use strict;
use FindBin qw($Bin);
use Getopt::Long::Descriptive;
use JSON;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use XML::Simple;
our $have_config;
eval
{
    require Bio::KBase::AppService::AppConfig;
    $have_config = 1;
};
    

use lib "$Bin";
use SolrAPI;

my ($data_api_url, $reference_data_dir);
if ($have_config)
{
    $data_api_url = Bio::KBase::AppService::AppConfig->data_api_url;
    $reference_data_dir = Bio::KBase::AppService::AppConfig->reference_data_dir;
}else{
		$data_api_url = $ENV{PATRIC_DATA_API};
		$reference_data_dir = $ENV{PATRIC_REFERENCE_DATA};	
}

my $json = JSON->new->allow_nonref;

my ($opt, $usage) = describe_options("%c %o",
				[],
				["genomeobj-file=s", "RASTtk annotations as GenomeObj.json file"],
				["new-genomeobj-file=s", "New RASTtk annotations as GenomeObj.json file"],
				["data-api-url=s", "Data API URL", { default => $data_api_url }],
				["reference-data-dir=s", "Data API URL", { default => $reference_data_dir }],
				[],
				["help|h", "Print usage message and exit"] );

print($usage->text), exit 0 if $opt->help;
die($usage->text) unless $opt->genomeobj_file;

my $solrh = SolrAPI->new($opt->data_api_url, $opt->reference_data_dir);

my $genomeobj_file = $opt->genomeobj_file;
my $outfile = $opt->new_genomeobj_file? $opt->new_genomeobj_file : $genomeobj_file.".new";

print "Processing $genomeobj_file\n";

# Read GenomeObj
open GOF, $genomeobj_file or die "Can't open input RASTtk GenomeObj JSON file: $genomeobj_file\n";
my @json_array = <GOF>;
my $json_str = join "", @json_array;
close GOF;

my $genomeObj = $json->decode($json_str);


# Get EC, pathway, and spgene reference dictionaries
my $ecRef = $solrh->getECRef();
my $pathwayRef = $solrh->getPathwayRef();
my $spgeneRef = $solrh->getSpGeneRef();


# Process GenomeObj
genomeQuality();

# write to json files
writeJson();


sub writeJson {

	print "Preparing new GTO file...\n";

	my $genome_json = $json->pretty->encode($genomeObj);	
	open FH, ">$outfile" or die "Cannot write $outfile: $!"; 
	print FH "[".$genome_json."]";
	close FH;

}


sub genomeQuality {

	print "Preparing genome QC and summary stats ...\n";

	my ($chromosomes, $plasmids, $contigs, $sequences, $cds, $genome_length, $gc_count, $taxon_lineage_ranks);

	# Taxon lineage ids and names
	($genomeObj->{taxon_lineage_ids}, $genomeObj->{taxon_lineage_names}, $taxon_lineage_ranks)  = $solrh->getTaxonLineage($genomeObj->{ncbi_taxonomy_id});
	
	# Identify species, needed for comparing to species level stats 
	for(my $i=0; $i < scalar @{$taxon_lineage_ranks}; $i++){
		$genomeObj->{species} = $genomeObj->{taxon_lineage_names}[$i] if $$taxon_lineage_ranks[$i]=~/species/i;
	}

	# Read the existing genome quality data
	my $qc = $genomeObj->{genome_quality_measure};

	# Compute assembly stats
	my @contig_lengths = ();
	foreach my $seqObj (@{$genomeObj->{contigs}}) {
		$qc->{chromosomes}++ if $seqObj->{genbank_locus}->{definition}=~/chromosome|complete genome/i;
		$qc->{plasmids}++ if $seqObj->{genbank_locus}->{definition}=~/plasmid/i;
		$qc->{contigs}++;

		push @contig_lengths, length($seqObj->{dna});
		$qc->{genome_length} += length($seqObj->{dna});

		$gc_count += $seqObj->{dna}=~tr/GCgc//;
	}
	
	$qc->{gc_content} = sprintf("%.2f", ($gc_count*100/$qc->{genome_length}));
	$qc->{genome_status} = "Plasmid" if ($qc->{contigs} == $qc->{plasmids});

	# Compute L50 and N50
	my @contig_lengths_sorted = sort { $b <=> $a } @contig_lengths;
	my ($i,$total_length)=(0,0);
	foreach my $length (@contig_lengths_sorted){
		$i++;
		$total_length += $length;
		last if $total_length >= $qc->{genome_length}/2;	
	}
	$qc->{contig_l50} = $i;
	$qc->{contig_n50} = $total_length;

	# Compute annotation stats
	foreach my $feature (@{$genomeObj->{features}}){		
	
		# Feature summary	
		if ($feature->{type}=~/CDS/){
			$qc->{feature_summary}->{cds}++;
			$qc->{feature_summary}->{partial_cds}++ unless $feature->{protein_translation};
		}elsif ($feature->{type}=~/rna/i && $feature->{function}=~/rRNA/i){
			$qc->{feature_summary}->{rRNA}++;
		}elsif ($feature->{type}=~/rna/i && $feature->{function}=~/tRNA/i){
			$qc->{feature_summary}->{tRNA}++;
		}elsif ($feature->{type}=~/rna/){
			$qc->{feature_summary}->{misc_RNA}++;
		}elsif ($feature->{type}=~/repeat/){
			$qc->{feature_summary}->{repeat_region}++;
		}

		# If CDS, process for protein summary, else skip to next feature
		next unless $feature->{type}=~/CDS/;
		
		# Protein summary
		$qc->{protein_summary}->{hypothetical}++ if $feature->{function}=~/hypothetical protein/i;
		$qc->{protein_summary}->{function_assignment}++ unless $feature->{function}=~/hypothetical protein/i;
		
		foreach my $family (@{$feature->{family_assignments}}){
			$qc->{protein_summary}->{plfam_assignment}++ if @{$family}[0]=~/plfam/i;
			$qc->{protein_summary}->{pgfam_assignment}++ if @{$family}[0]=~/pgfam/i;
		}

		my (@segments, @go, @ec_no, @ec, @pathways, @spgenes);
	
		@ec_no = $feature->{function}=~/\( *EC[: ]([\d-\.]+) *\)/g if $feature->{function}=~/EC[: ]/;
		foreach my $ec_number (@ec_no){

			my $ec_description = $ecRef->{$ec_number}->{ec_description};
			push @ec, $ec_number.'|'.$ec_description unless (grep {$_ eq $ec_number.'|'.$ec_description} @ec);
			
			foreach my $go_term (@{$ecRef->{$ec_number}->{go}}){
				push @go, $go_term unless (grep {$_ eq $go_term} @go);
			}
			
			foreach my $pathway (@{$pathwayRef->{$ec_number}->{pathway}}){
				my ($pathway_id, $pathway_name, $pathway_class) = split(/\t/, $pathway);
				push @pathways, $pathway_id.'|'.$pathway_name unless (grep {$_ eq $pathway_id.'|'.$pathway_name} @pathways);
			}

		}
		$qc->{protein_summary}->{ec_assignment}++ if scalar @ec;
		$qc->{protein_summary}->{go_assignment}++ if scalar @go;
		$qc->{protein_summary}->{pathway_assignment}++ if scalar @pathways;

		# Specialty gene summary
		foreach my $spgene (@{$feature->{similarity_associations}}){
			my ($source, $source_id, $qcov, $scov, $identity, $evalue) = @{$spgene};
			$source_id=~s/^\S*\|//;
			my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
      = split /\t/, $spgeneRef->{$source.'_'.$source_id} if ($source && $source_id);
			$qc->{specialty_gene_summary}->{$property.":".$source}++;	
		}

		# PATRIC AMR gene summary 
		if ($spgeneRef->{$feature->{function}}){
			my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
      = split /\t/, $spgeneRef->{$feature->{product}};
			$qc->{specialty_gene_summary}->{"Antibiotic Resitsance:PATRIC"}++;
			push @{$qc->{amr_genes}}, [$feature->{id},$feature->{function}];
		}
		$qc->{specialty_gene_summary}->{"Antibiotic Resitsance:PATRIC"}++ if $spgeneRef->{$feature->{function}};
	
	} # finished processing all features

	# Subsystem summary
	foreach my $subsystem (@{$genomeObj->{subsystems}}){
		my ($superclass, $class, $subclass) = @{$subsystem->{classification}};
		$qc->{subsystem_summary}->{$superclass}->{subsystems}++;
		foreach my $role (@{$subsystem->{role_bindings}}){
			$qc->{subsystem_summary}->{$superclass}->{genes}++ foreach(@{$role->{features}});
		}	
	}

	# Additional genome stats based on annotation summary 
	$qc->{cds_ratio} = sprintf "%.2f", $qc->{feature_summary}->{cds} * 1000 / $qc->{genome_length};
	$qc->{hypothetical_cds_ratio} = sprintf "%.2f", $qc->{protein_summary}->{hypothetical} / $qc->{feature_summary}->{cds};
	$qc->{partial_cds_ratio} = sprintf "%.2f", $qc->{feature_summary}->{partial_cds} / $qc->{feature_summary}->{cds};
	$qc->{plfam_cds_ratio} = sprintf "%.2f", $qc->{protein_summary}->{plfam_assignment} / $qc->{feature_summary}->{cds};

	# Prepare Genome quality flagsBased on the assembly and annotation stats
	
	# Genome quality flags blased on genome assembly quality
	push @{$qc->{genome_quality_flags}}, "High contig L50" if $qc->{contig_l50} > 500;
  push @{$qc->{genome_quality_flags}}, "Low contig N50" if $qc->{contig_n50} < 5000;
	
	push @{$qc->{genome_quality_flags}}, "Plasmid only" if $qc->{genome_status} =~/plasmid/i; 
	push @{$qc->{genome_quality_flags}}, "Metagenomic bin" if $qc->{genome_status} =~/metagenome bin/i; 
	
	#push @{$qc->{genome_quality_flags}}, "Misidentified taxon"
	#	if $genomeObj->{infered_taxon} && not $genomeObj->{scientific_name} =~/$genomeObj->{infered_taxon}/i;
	
	push @{$qc->{genome_quality_flags}}, "Too many contigs" if $qc->{contigs} > 1000;
	
	push @{$qc->{genome_quality_flags}}, "Genome too long" if $qc->{genome_length} > 15000000;
	push @{$qc->{genome_quality_flags}}, "Genome too short" if $qc->{genome_length} < 300000;

	push @{$qc->{genome_quality_flags}}, "Low CheckM completeness score" 
		if $qc->{checkm_data}->{Completeness} && $qc->{checkm_data}->{Completeness} < 80;
	push @{$qc->{genome_quality_flags}}, "High CheckM contamination score" 
		if $qc->{checkm_data}->{Contamination} && $qc->{checkm_data}->{Contamination} > 10;
	push @{$qc->{genome_quality_flags}}, "Low Fine consistency score" 
		if $qc->{fine_consistency} && $qc->{fine_consistency} < 85;

	# Genome quality flags based on annotation quality
	push @{$qc->{genome_quality_flags}}, "No CDS" unless $qc->{feature_summary}->{cds};	
	push @{$qc->{genome_quality_flags}}, "Abnormal CDS ratio" if $qc->{cds_ratio} < 0.5 || $qc->{cds_ratio} > 1.5;
	push @{$qc->{genome_quality_flags}}, "Too many hypothetical CDS" if $qc->{hypothetical_cds_ratio} > 0.7;
	push @{$qc->{genome_quality_flags}}, "Too many partial CDS" if $qc->{partial_cds_ratio} > 0.3;

	# Genome quality flags based on comparison with species stats
	# Not implemented yet

	# Overall genome quality 
	if (scalar @{$qc->{genome_quality_flags}}){
		$qc->{genome_quality} = "Poor";
	}else{
		$qc->{genome_quality} = "Good";
	} 

	# Update the genome quality measure obj in the GTO
	$genomeObj->{genome_quality_measure} = $qc;

}

