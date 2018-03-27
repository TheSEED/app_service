#!/usr/bin/env perl

###########################################################
#
# gtoQC.pl: 
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

#subsystemSummary();

# write to json files
writeJson();


sub writeJson {

	print "Preparing JSON files ...\n";

	my $genome_json = $json->pretty->encode($genomeObj);	
	open FH, ">$outfile" or die "Cannot write $outfile: $!"; 
	print FH "[".$genome_json."]";
	close FH;

}


sub genomeQuality {

	print "Getting genome metadata ...\n";

	my ($chromosomes, $plasmids, $contigs, $sequences, $cds, $genome_length, $gc_count, $taxon_lineage_ranks);

	($genomeObj->{taxon_lineage_ids}, $genomeObj->{taxon_lineage_names}, $taxon_lineage_ranks)  = $solrh->getTaxonLineage($genomeObj->{ncbi_taxonomy_id});

	for(my $i=0; $i < scalar @{$taxon_lineage_ranks}; $i++){
		$genomeObj->{species} = $genomeObj->{taxon_lineage_names}[$i] if $$taxon_lineage_ranks[$i]=~/species/i;
	}

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

		foreach my $spgene (@{$feature->{similarity_associations}}){
			my ($source, $source_id, $qcov, $scov, $identity, $evalue) = @{$spgene};
			$source_id=~s/^\S*\|//;
			my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
      = split /\t/, $spgeneRef->{$source.'_'.$source_id} if ($source && $source_id);
			$qc->{specialty_gene_summary}->{$property.":".$source}++;	
		}

		if ($spgeneRef->{$feature->{function}}){
			my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion)
      = split /\t/, $spgeneRef->{$feature->{product}};
			$qc->{specialty_gene_summary}->{"Antibiotic Resitsance:PATRIC"}++;
			push @{$qc->{amr_genes}}, [$feature->{id},$feature->{function}];
		}
		$qc->{specialty_gene_summary}->{"Antibiotic Resitsance:PATRIC"}++ if $spgeneRef->{$feature->{function}};
	
	}

	foreach my $subsystem (@{$genomeObj->{subsystems}}){
		my ($superclass, $class, $subclass) = @{$subsystem->{classification}};
		$qc->{subsystem_summary}->{$superclass}->{subsystems}++;
		foreach my $role (@{$subsystem->{role_bindings}}){
			$qc->{subsystem_summary}->{$superclass}->{genes}++ foreach(@{$role->{features}});
		}	
	}

	$qc->{cds_ratio} = sprintf "%.2f", $qc->{feature_summary}->{cds} * 1000 / $qc->{genome_length};
	$qc->{hypothetical_cds_ratio} = sprintf "%.2f", $qc->{protein_summary}->{hypothetical} / $qc->{feature_summary}->{cds};
	$qc->{partial_cds_ratio} = sprintf "%.2f", $qc->{feature_summary}->{partial_cds} / $qc->{feature_summary}->{cds};
	$qc->{plfam_cds_ratio} = sprintf "%.2f", $qc->{protein_summary}->{plfam_cds} / $qc->{feature_summary}->{cds};


	# QC flags blased on genome assembly quality
	push @{$qc->{genome_quality_flags}}, "High contig L50" if $qc->{contig_l50} > 500;
  push @{$qc->{genome_quality_flags}}, "Low contig N50" if $qc->{contig_n50} < 5000;
	
	push @{$qc->{genome_quality_flags}}, "Plasmid only" if $qc->{genome_status} =~/plasmid/i; 
	push @{$qc->{genome_quality_flags}}, "Metagenomic bin" if $qc->{genome_status} =~/metagenome bin/i; 
	#push @{$genome->{genome_quality_flags}}, "Misidentified taxon" if $genome->{infered_taxon} && not $genome->{genome_name} =~/$genome->{predicted_species}/i;
	
	push @{$qc->{genome_quality_flags}}, "Too many contigs" if $qc->{contigs} > 1000;
	
	push @{$qc->{genome_quality_flags}}, "Genome too long" if $qc->{genome_length} > 15000000;
	push @{$qc->{genome_quality_flags}}, "Genome too short" if $qc->{genome_length} < 300000;

	push @{$qc->{genome_quality_flags}}, "Low CheckM completeness score" 
		if $qc->{checkm_data}->{Completeness} && $qc->{checkm_data}->{Completeness} < 80;
	push @{$qc->{genome_quality_flags}}, "High CheckM contamination score" 
		if $qc->{checkm_data}->{Contamination} && $qc->{checkm_data}->{Contamination} > 10;
	push @{$qc->{genome_quality_flags}}, "Low Fine consistency score" 
		if $qc->{fine_consistency} && $qc->{fine_consistency} < 85;


	# QC flags based on annotation quality
	push @{$qc->{genome_quality_flags}}, "No CDS" unless $qc->{feature_summary}->{cds};	
	push @{$qc->{genome_quality_flags}}, "Abnormal CDS ratio" if $qc->{cds_ratio} < 0.5 || $qc->{cds_ratio} > 1.5;
	push @{$qc->{genome_quality_flags}}, "Too many hypothetical CDS" if $qc->{hypothetical_cds_ratio} > 0.7;
	push @{$qc->{genome_quality_flags}}, "Too many partial CDS" if $qc->{partial_cds_ratio} > 0.3;


	$genomeObj->{genome_quality_measure} = $qc;

}

=pod
sub getGenomeFeatures{
	
	print "Getting genome features ...\n";

	foreach my $featObj (@{$genomeObj->{features}}){
			
		my ($feature, $sequence, $pathways, $ecpathways);
		my (@segments, @go, @ec_no, @ec, @pathways, @ecpathways, @spgenes, @uniprotkb_accns, @ids);

		$feature->{owner} = $genome->{owner};
		$feature->{public} = $public;
		$feature->{annotation} = $annotation;
			
		$feature->{genome_id} = $genome->{genome_id};

		$feature->{genome_name} = $genome->{genome_name};
		$feature->{taxon_id} = $genome->{taxon_id};

		$feature->{patric_id} = $featObj->{id};

		$feature->{feature_type} = $featObj->{type};
		$feature->{feature_type} = $1 if ($featObj->{type} eq "rna" && $featObj->{function}=~/(rRNA|tRNA)/);
		$feature->{feature_type} = 'misc_RNA' if ($featObj->{type} eq "rna" && !($featObj->{function}=~/rRNA|tRNA/));
		$feature->{feature_type} = 'repeat_region' if ($featObj->{type} eq "repeat");

		$feature->{product} = $featObj->{function};
		$feature->{product} = "hypothetical protein" if ($feature->{feature_type} eq 'CDS' && !$feature->{product});
		$feature->{product}=~s/\"/''/g;
		$feature->{product}=~s/^'* *| *'*$//g;
		
		foreach my $locObj (@{$featObj->{location}}){
			
			my ($seq_id, $pstart, $start, $end, $strand, $length);

			($seq_id, $pstart, $strand, $length) = @{$locObj};
			
			if ($strand eq "+"){
				$start = $pstart;
				$end = $start+$length-1;
			}else{
				$end = $pstart;
				$start = $pstart-$length+1;
			}
			push @segments, $start."..". $end;

			$feature->{sequence_id} = $seq{$seq_id}{sequence_id};
			$feature->{accession} = $seq{$seq_id}{accession};

			$feature->{start} = $start if ($start < $feature->{start} || !$feature->{start});
			$feature->{end} = $end if ($end > $feature->{end} || !$feature->{end});
			$feature->{strand} = $strand;

			$sequence .= substr($seq{$seq_id}{sequence}, $start-1, $length);

		}

		$sequence =~tr/ACGTacgt/TGCAtgca/ if $feature->{strand} eq "-";
		$sequence = reverse($sequence) if $feature->{strand} eq "-";

		$feature->{segments} = \@segments;
		$feature->{location} = $feature->{strand} eq "+"? join(",", @segments): "complement(".join(",", @segments).")"; 

		$feature->{pos_group} = "$feature->{sequence_id}:$feature->{end}:+" if $feature->{strand} eq '+';			
		$feature->{pos_group} = "$feature->{sequence_id}:$feature->{start}:-" if $feature->{strand} eq '-';

		$feature->{na_sequence} = $sequence; 
		$feature->{na_length} = length($sequence) unless $feature->{feature_type} eq "source";

		$feature->{aa_sequence} = $featObj->{protein_translation};
		$feature->{aa_length} 	= length($feature->{aa_sequence}) if ($feature->{aa_sequence});
		$feature->{aa_sequence_md5} = md5_hex($feature->{aa_sequence}) if ($feature->{aa_sequence});

		my $strand = ($feature->{strand} eq '+')? 'fwd':'rev';
		$feature->{feature_id}		=	"$annotation.$feature->{genome_id}.$feature->{accession}.".
																	"$feature->{feature_type}.$feature->{start}.$feature->{end}.$strand";



		foreach my $alias (@{$featObj->{alias_pairs}}){
			my ($alias_type, $alias_value) = @{$alias};
			$feature->{refseq_locus_tag} = $alias_value if ($alias_type eq "locus_tag");
			#$feature->{refseq_locus_tag} = $alias_value if ($alias_type eq "old_locus_tag");
			$feature->{protein_id} = $alias_value if ($alias_type eq "");
			$feature->{gene_id} = $alias_value if ($alias_type eq "GeneID");
			$feature->{gi} = $alias_value if ($alias_type eq "GI");
			$feature->{gene} = $alias_value if ($alias_type eq "gene");
		}

		foreach my $family (@{$featObj->{family_assignments}}){
			my ($family_type, $family_id, $family_function) = @{$family};
			$feature->{figfam_id} = $family_id if ($family_id=~/^FIG/);
			$feature->{plfam_id} = $family_id if ($family_id=~/^PLF/);
			$feature->{pgfam_id} = $family_id if ($family_id=~/^PGF/);
		}

		@ec_no = $feature->{product}=~/\( *EC[: ]([\d-\.]+) *\)/g if $feature->{product}=~/EC[: ]/;

		foreach my $ec_number (@ec_no){

			my $ec_description = $ecRef->{$ec_number}->{ec_description};
			push @ec, $ec_number.'|'.$ec_description unless (grep {$_ eq $ec_number.'|'.$ec_description} @ec);
			
			foreach my $go_term (@{$ecRef->{$ec_number}->{go}}){
				push @go, $go_term unless (grep {$_ eq $go_term} @go);
			}
			
			foreach my $pathway (@{$pathwayRef->{$ec_number}->{pathway}}){
				my ($pathway_id, $pathway_name, $pathway_class) = split(/\t/, $pathway);
				push @pathways, $pathway_id.'|'.$pathway_name unless (grep {$_ eq $pathway_id.'|'.$pathway_name} @pathways);
				my $ecpathway = "$ec_number\t$ec_description\t$pathway_id\t$pathway_name\t$pathway_class";
				push @ecpathways, $ecpathway unless (grep {$_ eq $ecpathway} @ecpathways);
			}

		}

		$feature->{ec} = \@ec if scalar @ec;
		$feature->{go} = \@go if scalar @go;
		$feature->{pathway} = \@pathways if scalar @pathways;
		push @pathwaymap, preparePathways($feature, \@ecpathways);

		@spgenes = @{$featObj->{similarity_associations}} if $featObj->{similarity_associations};			
		push @spgenemap, prepareSpGene($feature, $_) foreach(@spgenes);

		# Prepare PATRIC AMR genes for matching functions 
		push @spgenemap, prepareSpGene($feature, ()) if $spgeneRef->{$feature->{product}};

		push @features, $feature  unless $feature->{feature_type} eq 'gene'; 

		$genome->{lc($annotation).'_cds'}++ if $feature->{feature_type} eq 'CDS';

	}

}


sub prepareSpGene {

		my ($feature, $spgene_match) = @_;

		my $spgene;
		my ($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion); 
		my ($source, $source_id, $qcov, $scov, $identity, $evalue);

		if($spgene_match){ # All specialty genes from external sources
			($source, $source_id, $qcov, $scov, $identity, $evalue) = @$spgene_match;
			$source_id=~s/^\S*\|//;
			($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion) 
			= split /\t/, $spgeneRef->{$source.'_'.$source_id} if ($source && $source_id);
		}elsif($spgeneRef->{$feature->{product}}){ # PATRIC AMR genes, match by functional role
			($property, $locus_tag, $organism, $function, $classification, $antibiotics_class, $antibiotics, $pmid, $assertion) 
			= split /\t/, $spgeneRef->{$feature->{product}};
			$source = "PATRIC";	
		}

		return unless $property && $source;

		my ($qgenus) = $feature->{genome_name}=~/^(\S+)/;
		my ($qspecies) = $feature->{genome_name}=~/^(\S+ +\S+)/;
		my ($sgenus) = $organism=~/^(\S+)/;
		my ($sspecies) = $organism=~/^(\S+ +\S+)/;

		my ($same_genus, $same_species, $same_genome, $evidence); 

		$same_genus = 1 if ($qgenus eq $sgenus && $sgenus ne "");
		$same_species = 1 if ($qspecies eq $sspecies && $sspecies ne ""); 
		$same_genome = 1 if ($feature->{genome} eq $organism && $organism ne "") ;

		$evidence = ($source && $source_id)? 'BLAT' : "K-mer Search";

		$spgene->{owner} = $feature->{owner};
		$spgene->{public} = $public;
		
		$spgene->{genome_id} = $feature->{genome_id};	
		$spgene->{genome_name} = $feature->{genome_name};	
		$spgene->{taxon_id} = $feature->{taxon_id};	
		
		$spgene->{feature_id} = $feature->{feature_id};
		$spgene->{patric_id} = $feature->{patric_id};	
		$spgene->{alt_locus_tag} = $feature->{alt_locus_tag};
		$spgene->{refseq_locus_tag} = $feature->{refseq_locus_tag};
		
		$spgene->{gene} = $feature->{gene};
		$spgene->{product} = $feature->{product};

		$spgene->{property} = $property;
		$spgene->{source} = $source;
		$spgene->{property_source} = $property.': '.$source;
		
		$spgene->{source_id} = $source_id;
		$spgene->{organism} = $organism;
		$spgene->{function} = $function;
		$spgene->{classification} = $classification; 
		$spgene->{antibiotics_class} = $antibiotics_class if $antibiotics_class;
		$spgene->{antibiotics} = [split /[,;]/, $antibiotics] if $antibiotics;
		$spgene->{pmid} = [split /[,;]/, $pmid] if $pmid;
		$spgene->{assertion} = $assertion;

		$spgene->{query_coverage} = $qcov; 
		$spgene->{subject_coverage} =  $scov;
		$spgene->{identity} = $identity;
		$spgene->{e_value} = $evalue;

		$spgene->{same_genus} = $same_genus;
		$spgene->{same_species} = $same_species;
		$spgene->{same_genome} = $same_genome;
	  $spgene->{evidence} = $evidence;	

		return $spgene;
}


sub preparePathways {

	my ($feature, $ecpathways) = @_;
	my @pathways = ();

	foreach my $ecpathway (@$ecpathways){
		my $pathway;
		my ($ec_number, $ec_description, $pathway_id, $pathway_name, $pathway_class) = split /\t/, $ecpathway;
		
		$pathway->{owner} = $feature->{owner};
		$pathway->{public} = $public;

		$pathway->{genome_id} = $feature->{genome_id};
		$pathway->{genome_name} = $feature->{genome_name};
		$pathway->{taxon_id} = $feature->{taxon_id};

		$pathway->{sequence_id} = $feature->{sequence_id};
		$pathway->{accession} = $feature->{accession};
		
		$pathway->{annotation} = $feature->{annotation};
		
		$pathway->{feature_id} = $feature->{feature_id};
		$pathway->{patric_id} = $feature->{patric_id};
		$pathway->{alt_locus_tag} = $feature->{alt_locus_tag};
		$pathway->{refseq_locus_tag} = $feature->{refseq_locus_tag};
		
		$pathway->{gene} = $feature->{gene};
		$pathway->{product} = $feature->{product};
		
		$pathway->{ec_number} = $ec_number;
		$pathway->{ec_description} = $ec_description;
		
		$pathway->{pathway_id} = $pathway_id;
		$pathway->{pathway_name} = $pathway_name;
		$pathway->{pathway_class} = $pathway_class;
		
		$pathway->{genome_ec} = $feature->{genome_id}.'_'.$ec_number;
		$pathway->{pathway_ec} = $pathway_id.'_'.$ec_number;

		push @pathways, $pathway;

	}

	return @pathways;

}

=cut
