#!/usr/bin/perl

###########################################################
#
# genomeObj2solr.pl: 
#
# Script to convert RASTtk genome object into separate JSON
# objects for each of the Solr cores.  
#
# Input: JSON file containing RASTtk genome object
# 
# Output: Five JSON files each correspodning to a Solr core:
#	   genome.json, genome_sequence.json, genome_feature.json,
#	   pathway.json, sp_gene.json  
#
# Usage: genomeObj2solr.pl annotation.genome
#
###########################################################

use FindBin qw($Bin);
use POSIX;
use JSON;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);

use lib "$Bin";
use SolrAPI;

my $solrh = SolrAPI->new();
my $json = JSON->new->allow_nonref;

my $usage = "genomeObj2solr.pl genbankFile\n";

my $infile = $ARGV[0];
my $outfile = $infile;
$outfile=~s/(.gb|.gbf|.json)$//;	

open IN, $infile or die "Can't open input RAST GenomeObj JSON file: $infile\n";
my @in = <IN>;
my $json_str = join "", @in;
close IN;

my $jsonh = JSON->new->allow_nonref;
my $genomeObj = $jsonh->decode($json_str);

print "Processing $infile\n";

my $public = 0;
my $annotation = "PATRIC";
my $sequence_type = "contig";

my $ecRef = $solrh->getECRef();
my $pathwayRef = $solrh->getPathwayRef();
my $spgeneRef = $solrh->getSpGeneRef();

my %seq=();

my $genome;
my @sequences = ();
my @features = ();
my @pathwaymap = ();
my @spgenemap = (); 


getGenomeInfo();
getGenomeSequences();
getGenomeFeatures();
writeJson();

sub writeJson {

	my $genome_json = $json->pretty->encode($genome);
	my $sequence_json = $json->pretty->encode(\@sequences);
	my $feature_json = $json->pretty->encode(\@features);
	my $pathwaymap_json = $json->pretty->encode(\@pathwaymap);
	my $spgenemap_json = $json->pretty->encode(\@spgenemap);

	open FH, ">genome.json"; 
	print FH "[".$genome_json."]";
	close FH;

	open FH, ">genome_sequence.json"; 
	print FH $sequence_json;
	close FH;

	open FH, ">genome_feature.json"; 
	print FH $feature_json;
	close FH;

	open FH, ">pathway.json"; 
	print FH $pathwaymap_json;
	close FH;

	open FH, ">sp_gene.json"; 
	print FH $spgenemap_json;
	close FH;

}

sub getGenomeInfo {

	my ($chromosomes, $plasmids, $contigs, $sequences, $cds, $genome_length, $gc_count, $taxon_lineage_ranks);

	$genome->{owner} = $genomeObj->{owner};
	$genome->{public} = $public;

	$genome->{genome_id} = $genomeObj->{id};
	$genome->{genome_name} = $genomeObj->{scientific_name};
	$genome->{common_name} = $genomeObj->{scientific_name};
	$genome->{common_name}=~s/\W+/_/g;

	$genome->{taxon_id}    =  $genomeObj->{ncbi_taxonomy_id};
	($genome->{taxon_lineage_ids}, $genome->{taxon_lineage_names}, $taxon_lineage_ranks)  = $solrh->getTaxonLineage($genome->{taxon_id});

	my $i=0;

	foreach my $rank (@{$taxon_lineage_ranks}){
		$genome->{kingdom} = $genome->{taxon_lineage_names}[$i] if $rank=~/kingdom/i;
		$genome->{phylum} = $genome->{taxon_lineage_names}[$i] if $rank=~/phylum/i;
		$genome->{class} = $genome->{taxon_lineage_names}[$i] if $rank=~/class/i;
		$genome->{order} = $genome->{taxon_lineage_names}[$i] if $rank=~/order/i;
		$genome->{family} = $genome->{taxon_lineage_names}[$i] if $rank=~/family/i;
		$genome->{genus} = $genome->{taxon_lineage_names}[$i] if $rank=~/genus/i;
		$genome->{species} = $genome->{taxon_lineage_names}[$i] if $rank=~/species/i;
		$i++;
	}

	foreach my $seqObj (@{$genomeObj->{contigs}}) {
	
		$contigs++;	
		$sequences++;
		$genome_length += length($seqObj->{dna});
		$gc_count += $seqObj->{dna}=~tr/GCgc//;
		
		}
			
	$genome->{contigs} = $contigs if $contigs ;
	$genome->{sequences} = $sequences;
	$genome->{genome_length} = $genome_length;
	$genome->{gc_content} = sprintf("%.2f", ($gc_count*100/$genome_length));
	$genome->{genome_status} = ($sequences > 1)? "WGS": "Complete";

}


sub getGenomeSequences {

	my $count=0;

	foreach my $seqObj (@{$genomeObj->{contigs}}){
		
		$count++;
		my $sequence;
		
		$sequence->{owner} = $genome->{owner};
		$sequence->{public} = $public;
	
		$sequence->{genome_id} = $genome->{genome_id};
		$sequence->{genome_name} = $genome->{genome_name};
		$sequence->{taxon_id} = $genome->{taxon_id};

		my $seq_id = $seqObj->{id};	

		$sequence->{sequence_id} = $sequence->{genome_id}.".con.".sprintf("%04d", $count);
		if($seq_id=~/gi\|(\d+)\|(ref|gb)\|([\w\.]+)/){
			$sequence->{gi} = $1;
			$sequence->{accession} = $3;
		}elsif($seq_id=~/accn\|([\w\.]+)/){
			$sequence->{accession} = $1;
		}else{
			$sequence->{accession} = $sequence->{sequence_id};
		}

		$sequence->{sequence_type} = $sequence_type;
		#$sequence->{topology} =	"";
		#$sequence->{description} = "";

		$sequence->{gc_content} = sprintf("%.2f", ($seqObj->{dna}=~tr/GCgc//)*100/length($seqObj->{dna}));
		$sequence->{length} = length($seqObj->{dna});
		$sequence->{sequence} = lc($seqObj->{dna});
		
		$seq{$seq_id}{sequence_id} = $sequence->{sequence_id};
		$seq{$seq_id}{accession} = $sequence->{accession};
		$seq{$seq_id}{sequence} = $sequence->{sequence};

		push @sequences, $sequence;

	}

}


sub getGenomeFeatures{
	

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
		$feature->{feature_type} = 'misc_RNA' if ($featObj->{type} eq "rna" && !$featObj->{function}=~/(rRNA|tRNA)/);
		$feature->{feature_type} = 'repeat_region' if ($featObj->{type} eq "repeat");

		$feature->{product} = $featObj->{function};
		$feature->{product} = "hypothetical protein" if ($feature->{feature_type} eq 'CDS' && !$feature->{product});
		$feature->{product}=~s/\"/''/g;
		
		foreach my $locObj (@{$featObj->{location}}){
			
			my ($seq_id, $pstart, $start, $end, $length);

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


		#$feature->{refseq_locus_tag} 	= $value if ($tag eq 'locus_tag' && $annotation eq "RefSeq");
		#$feature->{refseq_locus_tag} 	= $1 if ($tag eq 'db_xref' && $value=~/Refseq_locus_tag:(.*)/i);
		#$feature->{protein_id} 	= $value if ($tag eq 'protein_id');
		#$feature->{protein_id} 	= $1 if ($tag eq 'db_xref' && $value=~/protein_id:(.*)/);	
		#$feature->{gene_id} = $1 if ($tag eq 'db_xref' && $value=~/^GeneID:(\d+)/);
		#$feature->{gi} = $1 if ($tag eq 'db_xref' && $value=~/^GI:(\d+)/);	
		#$feature->{gene} = $value if ($tag eq 'gene');

		foreach my $family (@{$featObj->{family_assignments}}){
			my ($family_type, $family_id, $family_function) = @{$family};
			$feature->{figfam_id} = $family_id if ($family_type eq 'FIGFAM' && $family_id);
		}

		@ec_no = $feature->{product}=~/\( *EC[: ]([\d-\.]+) *\)/g;

		foreach my $ec_number (@ec_no){

			my $ec_description = $ecRef->{$ec_number}->{ec_description};
			push @ec, $ec_number.'|'.$ec_description unless (grep {$_ eq $ec_number.'|'.$ec_description} @ec);
			
			foreach my $go_term (@{$ecRef->{$ec_number}->{go}}){
				push @go, $go_term unless (grep {$_ eq $go_term} @go);
    	}
			
			foreach my $pathway (@{$pathwayRef->{$ec_number}->{pathway}}){
				my ($pathway_id, $pathway_name, $pathway_class) = split(/\t/, $pathway);
				push @pathways, $pathway_id.'|'.$pathway_name unless (grep {$_ eq $pathway_id.'|'.$pathway_name} @pathways);
				$ecpathway = "$ec_number\t$ec_description\t$pathway_id\t$pathway_name\t$pathway_class";
				push @ecpathways, $ecpathway unless (grep {$_ eq $ecpathway} @ecpathways);
			}

		}

		$feature->{ec} = \@ec if scalar @ec;
		$feature->{go} = \@go if scalar @go;
		$feature->{pathway} = \@pathways if scalar @pathways;
		push @pathwaymap, preparePathways($feature, \@ecpathways);

		@spgenes = @{$featObj->{similarity_associations}};			
		push @spgenemap, prepareSpGene($feature, $_) foreach(@spgenes);

		push @features, $feature  unless $feature->{feature_type} eq 'gene'; 

		$genome->{lc($annotation).'_cds'}++ if $feature->{feature_type} eq 'CDS';

	}

}


sub prepareSpGene {

		my ($feature, $spgene_match) = @_;
		my $spgene;

		my ($source, $source_id, $qcov, $scov, $identity, $evalue) = @$spgene_match;

		$source_id=~s/^\S*\|//;

		my ($property, $locus_tag, $organism, $function, $classification, $pmid, $assertion) 
			= split /\t/, $spgeneRef->{$source.'_'.$source_id} if ($source && $source_id);

		my ($qgenus) = $feature->{genome_name}=~/^(\S+)/;
		my ($qspecies) = $feature->{genome_name}=~/^(\S+ +\S+)/;
		my ($sgenus) = $organism=~/^(\S+)/;
		my ($sspecies) = $organism=~/^(\S+ +\S+)/;

		my ($same_genus, $same_species, $same_genome, $evidence); 

		$same_genus = 1 if ($qgenus eq $sgenus && $sgenus ne "");
		$same_species = 1 if ($qspecies eq $sspecies && $sspecies ne ""); 
		$same_genome = 1 if ($feature->{genome} eq $organism && $organism ne "") ;

		$evidence = ($feature->{refseq_locus_tag} && $locus_tag && $feature->{refseq_locus_tag} eq $locus_tag)? 'Literature':'BLASTP';

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

		$spgene->{pmid} = $pmid; 
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
		
		$pathway->{owner} = $owner;
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

