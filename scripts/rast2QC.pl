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
use Getopt::Long::Descriptive;
use FindBin qw($Bin);
use JSON;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use XML::Simple;
use GenomeTypeObject;

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
}
else
{
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

my $genomeObj = GenomeTypeObject->new({ file => $genomeobj_file });


# Get EC, pathway, and spgene reference dictionaries
my $ecRef = $solrh->getECRef();
my $pathwayRef = $solrh->getPathwayRef();
my $spgeneRef = $solrh->getSpGeneRef();

# Process GenomeObj
genomeQuality();

$genomeObj->destroy_to_file($outfile);

sub genomeQuality
{
    print "Preparing genome QC and summary stats ...\n";

    # Taxon lineage ids and names
    my($lineage_ids, $lineage_names, $lineage_ranks) = $solrh->getTaxonLineage($genomeObj->{ncbi_taxonomy_id});
		my $species;

    my $glin = $genomeObj->{ncbi_lineage} = [];
    # Identify species, needed for comparing to species level stats 
    for (my $i=0; $i < @$lineage_ranks; $i++)
    {
			push(@$glin, [$lineage_names->[$i], $lineage_ids->[$i], $lineage_ranks->[$i]]);
			if ($lineage_ranks->[$i] =~ /species/i)
			{
				$genomeObj->{ncbi_species} = $lineage_names->[$i];
				$species = $solrh->getSpeciesInfo($lineage_ids->[$i]);
				#$species = $solrh->getSpeciesInfo("817");
			}
			$genomeObj->{ncbi_genus} = $lineage_names->[$i] if $lineage_ranks->[$i] =~ /genus/i;
    }

    # Read the existing genome quality data
    my $qc = $genomeObj->{genome_quality_measure};
    
    # Compute assembly stats
    foreach my $seqObj (@{$genomeObj->{contigs}})
    {
	$qc->{chromosomes}++ if $seqObj->{genbank_locus}->{definition}=~/chromosome|complete genome/i;
	$qc->{plasmids}++ if $seqObj->{genbank_locus}->{definition}=~/plasmid/i;
	$qc->{contigs}++;
    }
	
    $qc->{gc_content} = $genomeObj->compute_contigs_gc();
		
		if ($qc->{contigs} == $qc->{chromosomes}+$qc->{plasmids})
		{
			$qc->{genome_status} = "Complete";
		}elsif ($qc->{contigs} == $qc->{plasmids})
		{
			$qc->{genome_status} = "Plasmid";
		}else
		{
			$qc->{genome_status} = "WGS";
		}

    # Compute L50 and N50
    #
    # Already computed by GenomeTypeObject::metrics
    #
    if (!exists $qc->{genome_metrics})
    {
	$qc->{genome_metrics} = $genomeObj->metrics();
    }

    # hoist genome length out of metrics
    $qc->{genome_length} = $qc->{genome_metrics}->{totlen};
    
    # Compute annotation stats

    my @keys = qw(cds partial_cds rRNA tRNA misc_RNA repeat_region);
    $qc->{feature_summary}->{$_} = 0 foreach @keys;
    
    foreach my $feature ($genomeObj->features())
    {
	# Feature summary	
	if ($feature->{type}=~/CDS/)
	{
	    $qc->{feature_summary}->{cds}++;
	    $qc->{feature_summary}->{partial_cds}++ unless $feature->{protein_translation};
	}
	elsif ($feature->{type}=~/rna/i && $feature->{function}=~/rRNA/i)
	{
	    $qc->{feature_summary}->{rRNA}++;
	}
	elsif ($feature->{type}=~/rna/i && $feature->{function}=~/tRNA/i)
	{
	    $qc->{feature_summary}->{tRNA}++;
	}
	elsif ($feature->{type}=~/rna/)
	{
	    $qc->{feature_summary}->{misc_RNA}++;
	}
	elsif ($feature->{type}=~/repeat/)
	{
	    $qc->{feature_summary}->{repeat_region}++;
	}

	# If CDS, process for protein summary, else skip to next feature
	next unless $feature->{type}=~/CDS/;
	
	# Protein summary
	if ($feature->{function}=~/hypothetical protein/i)
	{
	    $qc->{protein_summary}->{hypothetical}++;
	}
	else
	{	
	    $qc->{protein_summary}->{function_assignment}++;
	}
	
	foreach my $family (@{$feature->{family_assignments}})
	{
	    $qc->{protein_summary}->{plfam_assignment}++ if @{$family}[0]=~/plfam/i;
	    $qc->{protein_summary}->{pgfam_assignment}++ if @{$family}[0]=~/pgfam/i;
	}

	my (@segments, @go, @ec_no, @ec, @pathways, @spgenes);
	
	@ec_no = $feature->{function}=~/\( *EC[: ]([\d-\.]+) *\)/g if $feature->{function}=~/EC[: ]/;
	my %ec_seen;
	my %go_seen;
	my %pathway_seen;

	foreach my $ec_number (@ec_no)
	{
	    my $ec_description = $ecRef->{$ec_number}->{ec_description};
	    push @ec, [$ec_number, $ec_description] unless $ec_seen{$ec_number}++;
	    
	    foreach my $go_term (@{$ecRef->{$ec_number}->{go}}){
		push @go, [split(/\|/, $go_term, 2)] unless $go_seen{$go_term}++;
	    }
	    
	    foreach my $pathway (@{$pathwayRef->{$ec_number}->{pathway}}){
		my ($pathway_id, $pathway_name, $pathway_class) = split(/\t/, $pathway);
		push @pathways, [$pathway_id, $pathway_name] unless $pathway_seen{$pathway_id}++;
	    }
	    $feature->{ec_numbers} = [@ec];
	    $feature->{go_terms} = [@go];
	    $feature->{pathways} = [@pathways];
	}
	$qc->{protein_summary}->{ec_assignment}++ if @ec;
	$qc->{protein_summary}->{go_assignment}++ if @go;
	$qc->{protein_summary}->{pathway_assignment}++ if @pathways;

	# Specialty gene summary
	foreach my $spgene (@{$feature->{similarity_associations}})
	{
	    my ($source, $source_id, $qcov, $scov, $identity, $evalue) = @{$spgene};
	    $source_id=~s/^\S*\|//;
	    my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
		= split /\t/, $spgeneRef->{$source.'_'.$source_id} if ($source && $source_id);
	    $qc->{specialty_gene_summary}->{$property.":".$source}++;	
	}

	# PATRIC AMR gene summary 
	if ($spgeneRef->{$feature->{function}})
	{
	    my ($property, $gene_name, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
      = split /\t/, $spgeneRef->{$feature->{function}};
	    $qc->{specialty_gene_summary}->{"Antibiotic Resistance:PATRIC"}++;
	    push @{$qc->{amr_genes}}, [$feature->{id}, $gene_name, $feature->{function}, $classification];
	    #print "$feature->{id}\t$gene_name\n";
	    @{$qc->{amr_gene_summary}->{$classification}} = sort { lc $a cmp lc $b } @{$qc->{amr_gene_summary}->{$classification}}, $gene_name 
				unless (grep {$_ eq $gene_name} @{$qc->{amr_gene_summary}->{$classification}}) || $gene_name eq "";
	}
	#$qc->{specialty_gene_summary}->{"Antibiotic Resistance:PATRIC"}++ if $spgeneRef->{$feature->{function}};
	
    } # finished processing all features
    
    # Subsystem summary
    foreach my $subsystem (@{$genomeObj->{subsystems}})
    {
	my ($superclass, $class, $subclass) = @{$subsystem->{classification}};
	$qc->{subsystem_summary}->{$superclass}->{subsystems}++;
	foreach my $role (@{$subsystem->{role_bindings}})
	{
	    $qc->{subsystem_summary}->{$superclass}->{genes}++ foreach(@{$role->{features}});
	}	
    }

    # Additional genome stats based on annotation summary 
    $qc->{cds_ratio} =  $qc->{feature_summary}->{cds} * 1000 / $qc->{genome_length};
    if ($qc->{feature_summary}->{cds})
    {
	$qc->{hypothetical_cds_ratio} = $qc->{protein_summary}->{hypothetical} / $qc->{feature_summary}->{cds};
	$qc->{partial_cds_ratio} = $qc->{feature_summary}->{partial_cds} / $qc->{feature_summary}->{cds};
	$qc->{plfam_cds_ratio} = $qc->{protein_summary}->{plfam_assignment} / $qc->{feature_summary}->{cds};
	$qc->{pgfam_cds_ratio} = $qc->{protein_summary}->{pgfam_assignment} / $qc->{feature_summary}->{cds};
    }
    
    # Prepare Genome quality flags based on the assembly and annotation stats

    $qc->{genome_quality_flags} = [];
	
    # Genome quality flags blased on genome assembly quality
    push @{$qc->{genome_quality_flags}}, "High contig L50" if $qc->{genome_metrics}->{L50} > 500;
    push @{$qc->{genome_quality_flags}}, "Low contig N50" if $qc->{genome_metrics}->{N50} < 5000;
	
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
    push @{$qc->{genome_quality_flags}}, "No CDS"
			unless $qc->{feature_summary}->{cds};	
    push @{$qc->{genome_quality_flags}}, "Abnormal CDS ratio"
			if $qc->{cds_ratio} < 0.5 || $qc->{cds_ratio} > 1.5;
    push @{$qc->{genome_quality_flags}}, "Too many hypothetical CDS"
			if $qc->{hypothetical_cds_ratio} > 0.7;
    push @{$qc->{genome_quality_flags}}, "Too many partial CDS" 
			if $qc->{partial_cds_ratio} > 0.3;
    
    # Genome quality flags based on comparison with species stats
		push @{$qc->{genome_quality_flags}}, "Genome too short"
			if $qc->{genome_length} < $species->{genome_length_mean} - 3*$species->{genome_length_sd};
		push @{$qc->{genome_quality_flags}}, "Genome too long"
			if $qc->{genome_length} > $species->{genome_length_mean} + 3*$species->{genome_length_sd};
		
		push @{$qc->{genome_quality_flags}}, "Low CDS count"
			if $qc->{feature_summary}->{cds} < $species->{cds_mean} - 3*$species->{cds_sd};
		push @{$qc->{genome_quality_flags}}, "High CDS count"
			if $qc->{feature_summary}->{cds} > $species->{cds_mean} + 3*$species->{cds_sd};

		push @{$qc->{genome_quality_flags}}, "Too many hypothetical CDS" 
			if $qc->{feature_summary}->{hypothetical_cds_ratio} > $species->{hypothetical_cds_ratio_mean} + 3*$species->{hypothetical_cds_ratio_sd};

		push @{$qc->{genome_quality_flags}}, "Low PLfam CDS ratio" 
			if $qc->{feature_summary}->{plfam_cds_ratio} < $species->{plfam_cds_ratio_mean} - 3*$species->{plfam_cds_ratio_sd};


    # Overall genome quality 
    if (scalar @{$qc->{genome_quality_flags}}){
			$qc->{genome_quality} = "Poor";
    }else{
			$qc->{genome_quality} = "Good";
    } 
    
    # Update the genome quality measure obj in the GTO
    $genomeObj->{genome_quality_measure} = $qc;
}

