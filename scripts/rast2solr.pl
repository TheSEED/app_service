#!/usr/bin/perl

###########################################################
#
# rast2solr.pl: 
#
# Script to convert RASTtk genome object into separate JSON
# objects for each of the Solr cores.  
#
# Input: JSON file containing RASTtk genome object
#		Optional Original GenBank file used as input to RASTtk job 
# 
# Output: Five JSON files each correspodning to a Solr core:
#	   genome.json, genome_sequence.json, genome_feature.json,
#	   pathway.json, sp_gene.json  
#
# Usage: rast2solr.pl annotation.genome
#
###########################################################

use strict;
use FindBin qw($Bin);
use Getopt::Long::Descriptive;
use POSIX;
use JSON;
use Data::Dumper;
use Digest::MD5 qw(md5 md5_hex md5_base64);
use Bio::SeqIO;
use Bio::SeqFeature::Generic;
use Date::Parse;
use Bio::DB::EUtilities;
use XML::Simple;
use Bio::KBase::AppService::AppConfig;

use lib "$Bin";
use SolrAPI;

#my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;
#my $solrh = SolrAPI->new($data_api);

my $json = JSON->new->allow_nonref;

my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;

my ($opt, $usage) = describe_options( 
		"%c %o",
		[],
		["genomeobj-file=s", "RASTtk annotations as GenomeObj.json file"],
		["genbank-file=s", "Original GenBank file that was used as input to RASTtk"],
		["data-api=s", "Data API URL", { default => $data_api }],
		["public", "public, default is private"],
		[],
		["help|h", "Print usage message and exit"] );

print($usage->text), exit 0 if $opt->help;
die($usage->text) unless $opt->genomeobj_file;

my $solrh = SolrAPI->new($opt->data_api);

my $genomeobj_file = $opt->genomeobj_file;
my $genbank_file = $opt->genbank_file;
my $outfile = $genomeobj_file;
$outfile =~ s/(.gb|.gbf|.json)$//;

print "Processing $genomeobj_file\n";

# Read GenomeObj
open GOF, $genomeobj_file or die "Can't open input RASTtk GenomeObj JSON file: $genomeobj_file\n";
my @json_array = <GOF>;
my $json_str = join "", @json_array;
close GOF;

my $genomeObj = $json->decode($json_str);

# Set global parameters
my $public = $opt->public? 1 : 0;
my $annotation = "PATRIC"; 


# Get EC, pathway, and spgene reference dictionaries
my $ecRef = $solrh->getECRef();
my $pathwayRef = $solrh->getPathwayRef();
my $spgeneRef = $solrh->getSpGeneRef();


# Initialize global arrays to hold genome data
my %seq=();
my $genome;
my @sequences = ();
my @features = ();
my @pathwaymap = ();
my @spgenemap = (); 
my $featureIndex;


# Process GenomeObj
getGenomeInfo();
getGenomeSequences();
getGenomeFeatures();


# Process GenBank file and get additional data/metadata 
if (-f $genbank_file){

	# Get additional genome metadata 
	getMetadataFromGenBankFile($genbank_file);
	getMetadataFromBioProject($genome->{bioproject_accession}) if $genome->{bioproject_accession};
	getMetadataFromBioSample($genome->{biosample_accession}) if $genome->{biosample_accession};

	# Get additional features from the GenBank file
	getGenomeFeaturesFromGenBankFile($genbank_file);

}

# write to json files
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

	$genome->{owner} = $genomeObj->{owner}? $genomeObj->{owner} : "PATRIC";
	$genome->{public} = $public;

	$genome->{genome_id} = $genomeObj->{id};
	$genome->{genome_name} = $genomeObj->{scientific_name};
	$genome->{common_name} = $genomeObj->{scientific_name};
	$genome->{common_name}=~s/\W+/_/g;

	$genome->{taxon_id}    =  $genomeObj->{ncbi_taxonomy_id};
	($genome->{taxon_lineage_ids}, $genome->{taxon_lineage_names}, $taxon_lineage_ranks)  = $solrh->getTaxonLineage($genome->{taxon_id});

	my $i=0;
	for my $rank (@{$taxon_lineage_ranks}){
		$genome->{kingdom} = $genome->{taxon_lineage_names}[$i] if $rank=~/kingdom/i;
		$genome->{phylum} = $genome->{taxon_lineage_names}[$i] if $rank=~/phylum/i;
		$genome->{class} = $genome->{taxon_lineage_names}[$i] if $rank=~/class/i;
		$genome->{order} = $genome->{taxon_lineage_names}[$i] if $rank=~/order/i;
		$genome->{family} = $genome->{taxon_lineage_names}[$i] if $rank=~/family/i;
		$genome->{genus} = $genome->{taxon_lineage_names}[$i] if $rank=~/genus/i;
		$genome->{species} = $genome->{taxon_lineage_names}[$i] if $rank=~/species/i;
		$i++;
	}

	foreach my $type (@{$genomeObj->{typing}}){
		$genome->{mlst} .= "," if $genome->{mlst};
		$genome->{mlst} .= $type->{typing_method}.".".$type->{database}.".".$type->{tag};
	}	

	foreach my $seqObj (@{$genomeObj->{contigs}}) {

		if ($seqObj->{genbank_locus}->{definition}=~/chromosome|complete genome/i){
			$chromosomes++;	
		}elsif ($seqObj->{genbank_locus}->{definition}=~/plasmid/i){
			$plasmids++;
		}else{
			$contigs++;
		}

		$sequences++;
		$genome_length += length($seqObj->{dna});
		$gc_count += $seqObj->{dna}=~tr/GCgc//;

		if ($sequences == 1){
			foreach my $dblink (@{$seqObj->{genbank_locus}->{dblink}}){
				$genome->{bioproject_accession} = $1 if $dblink=~/BioProject:\s*(.*)/;
				$genome->{biosample_accession} = $1 if $dblink=~/BioSample:\s*(.*)/;
				$genome->{assembly_accession} = getAssemblyAccession($seqObj->{genbank_locus}->{gi}) if $seqObj->{genbank_locus}->{gi};				
			}
			foreach my $reference (@{$seqObj->{genbank_locus}->{references}}){
				$genome->{publication} .= $reference->{PUBMED}."," unless $genome->{publication}=~/$reference->{PUBMED}/;
			}
			$genome->{publication}=~s/,*$//g;
			$genome->{release_date} = strftime "%Y-%m-%dT%H:%M:%SZ", localtime str2time($seqObj->{genbank_locus}->{date});
		}
		$genome->{genbank_accessions} .= $seqObj->{genbank_locus}->{accession}[1]."," if $seqObj->{genbank_locus}->{accession}[1]=~/00000000$/;
		$genome->{genbank_accessions} .= $seqObj->{genbank_locus}->{accession}[0]."," unless $seqObj->{genbank_locus}->{accession}[1]=~/00000000$/;
	}
	$genome->{genbank_accessions}=~s/,*$//g;
	
  $genome->{chromosomes} = $chromosomes if $chromosomes;
  $genome->{plasmids} = $plasmids if $plasmids;
  $genome->{contigs} = $contigs if $contigs ;		
	$genome->{sequences} = $sequences;
	$genome->{genome_length} = $genome_length;
	$genome->{gc_content} = sprintf("%.2f", ($gc_count*100/$genome_length));
	$genome->{genome_status} = ($contigs > 1)? "WGS": "Complete";

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


		$sequence->{sequence_id} = $sequence->{genome_id}.".con.".sprintf("%04d", $count);

		my $seq_id = $seqObj->{id};	
		$sequence->{gi} = $seqObj->{genbank_locus}->{gi};

		if($seqObj->{genbank_locus}->{locus}){
			$sequence->{accession} = $seqObj->{genbank_locus}->{locus};
		}elsif($seq_id=~/gi\|(\d+)\|(ref|gb)\|([\w\.]+)/){
			$sequence->{gi} = $1;
			$sequence->{accession} = $3;
		}elsif($seq_id=~/accn\|([\w\.]+)/){
			$sequence->{accession} = $1;
		}else{
			$sequence->{accession} = $sequence->{sequence_id};
		}

		$sequence->{topology} =	$seqObj->{genbank_locus}->{geometry};
		$sequence->{description} = $seqObj->{genbank_locus}->{definition};

		if ($sequence->{description}=~/chromosome|complete genome/i){
			$sequence->{sequence_type} = "chromosome";
		}elsif ($sequence->{description}=~/plasmid/i){
			$sequence->{sequence_type} = "plasmid";
		}else{
			$sequence->{sequence_type} = "contig";
		}

		$sequence->{chromosome} = $1 if $sequence->{description}=~/chromosome (\S*)\s*,/i;
		$sequence->{plasmid} = $1 if $sequence->{description}=~/plasmid (\S*)\s*,/i;

		$sequence->{gc_content} = sprintf("%.2f", ($seqObj->{dna}=~tr/GCgc//)*100/length($seqObj->{dna}));
		$sequence->{length} = length($seqObj->{dna});
		$sequence->{sequence} = lc($seqObj->{dna});
	
		$sequence->{version} = $1 if $seqObj->{genbank_locus}->{version}[0]=~/^.*\.(\d+)$/;
		$sequence->{release_date} = strftime "%Y-%m-%dT%H:%M:%SZ", localtime str2time($seqObj->{genbank_locus}->{date});
	
		# look up hash
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


sub getMetadataFromGenBankFile {

	my ($genbak_file) = @_;

	open GB, "<$genbank_file";
	my @gb = <GB>;
	my $gb = join "", @gb;
	close GB;

	$genome->{geographic_location} =~s/\n */ /g;
	$genome->{geographic_location} = $1 if $gb=~/\/country="([^"]*)"/;
	
	$genome->{host_name} = $1 if $gb=~/\/host="([^"]*)"/;
	$genome->{host_name} =~s/\n */ /g;
  
	$genome->{isolation_source} = $1 if $gb=~/\/isolation_source="([^"]*)"/;
	$genome->{isolation_source} =~s/\n */ /g;
	
	$genome->{collection_date} = $1 if $gb=~/\/collection_date="([^"]*)"/;
	$genome->{collection_date} =~s/\n */ /g;

	$genome->{culture_collection} = $1 if $gb=~/\/culture_collection="([^"]*)"/;
	$genome->{culture_collection} =~s/\n */ /g;
	
	$genome->{assembly_method} = $1 if $gb=~/Assembly Method\s*:: (.*)/;
	$genome->{assembly_method} =~s/\n */ /g;
  
	$genome->{sequencing_depth} = $1 if $gb=~/Genome Coverage\s*:: (.*)/;
	$genome->{sequencing_depth} =~s/\n */ /g;
  
	$genome->{sequencing_platform} = $1 if $gb=~/Sequencing Technology\s*:: (.*)/;
	$genome->{sequencing_platform} =~s/\n */ /g;

}

sub getAssemblyAccession {

	my ($gi) = @_;

  my $xml = `wget -q -O - "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/elink.fcgi?dbfrom=nuccore&db=assembly&id=$gi"`;
  $xml=~s/\n//;
  my ($assembly_id) = $xml=~/<Link>\s*<Id>(\d+)<\/Id>/;

  my $xml = `wget -q -O - "http://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=assembly&id=$assembly_id"`;
  my ($assembly_accession) = $xml=~/<AssemblyAccession>(\S+)<\/AssemblyAccession>/;

	return $assembly_accession;

}

sub getMetadataFromBioProject {

	my($bioproject_accn) = @_;
	my $bioproject_id = $bioproject_accn;

	if ($bioproject_accn =~/^PRJ/){	
		my $eutil = Bio::DB::EUtilities->new(-eutil => 'esearch', -db => 'bioproject', -retmode => 'xml', -term => $bioproject_accn.'[Project Accession]');
		($bioproject_id) = $eutil->get_ids;
	}

	my $eutil = Bio::DB::EUtilities->new(-eutil => 'efetch', -db => 'bioproject', -retmode => 'xml', -id => $bioproject_id);
	$eutil->get_Response(-file => "$outfile.bioproject.xml");

	open XML, "$outfile.bioproject.xml";
	my $project = join("", <XML>);
	$project =~s/\n//g;
	close XML;

	#`rm $outfile.bioproject.xml`;

	my ($projID, $projDescription, $subgroup, $organism, $description, $var, $serovar, $biovar, $pathovar, $strain, $cultureCollection, $typeStrain);
	my ($isolateComment, $source, $month, $year, $country, $method, $person, $epidemic, $location, $altitude, $depth);
	my ($hostName, $hostGender, $hostAge, $hostHealth);
	my ($publication, $taxonID, $epidemiology);


	my $xml = XMLin("$outfile.bioproject.xml");
	my $root = $xml->{DocumentSummary};
	
	$genome->{sequencing_centers} = $root->{Submission}->{Description}->{Organization}->{Name}->{content};
	
	$organism = $root->{Project}->{ProjectType}->{ProjectTypeSubmission}->{Target}->{Organism};

	$genome->{strain} = $organism->{Strain};
	$genome->{disease} = $organism->{BiologicalProperties}->{Phenotype}->{Disease};
	$genome->{temperature_range} = $1 if $organism->{BiologicalProperties}->{Environment}->{TemperatureRange}=~/^e*(.*)/;
	$genome->{optimal_temperature} = $organism->{BiologicalProperties}->{Environment}->{OptimumTemperature};
	$genome->{oxygen_requirement} = $1 if $organism->{BiologicalProperties}->{Environment}->{OxygenReq}=~/^e*(.*)/;
	$genome->{habitat} = $1 if $organism->{BiologicalProperties}->{Environment}->{Habitat}=~/^e*(.*)/;	
	$genome->{cell_shape} = $1 if $organism->{BiologicalProperties}->{Morphology}->{Shape}=~/^e*(.*)/;
	$genome->{motility} = $1 if $organism->{BiologicalProperties}->{Morphology}->{Motility}=~/^e*(.*)/;
	$genome->{gram_stain} = $1 if $organism->{BiologicalProperties}->{Morphology}->{Gram}=~/^e*(.*)/;

	foreach my $pmid (keys %{$root->{Project}->{ProjectDescr}->{Publication}}){
		$genome->{publication} .= ",$pmid" unless $genome->{publication}=~/$pmid/; 
	}
	$genome->{publication}=~s/^,|,$//g;

	$description = $root->{Project}->{ProjectDescr}->{Description};

	$description=~s/&lt;\/*.&gt;|&#x0D;|<\/*.>//g;
	$description=~s/&lt;.*?&gt;|<.*?>//g;
	$description=~s/^ *|\t+| *$/ /g;
	$description=~s/Dr\.\s*/Dr /g;

	$typeStrain="Yes" if($description=~/type str/i);
		
	my($var1, $var2) = "$organism $description"=~/(serovar|sv\.|sv|serotype|biovar|bv\.|bv|biotype|pathovar|pv\.|pv|pathotype)\s*([\w-]*)/i;
	$var = "$var1 $var2" if($var2 && !($var2=~/^of|and$/i));
	$var =~s/serovar|sv\.|sv|serotype/serovar/i;
	$var =~s/biovar|bv\.|bv|biotype/biovar/i;
	$var =~s/pathovar|pv\.|pv|pathotype/pathovar/i;
	$var =~s/^\s*$//;
	$serovar = $var if($var=~/serovar/);
	$biovar = $var if($var=~/biovar/);
	$pathovar = $var if($var=~/pathovar/);

	my($cc1, $cc2) = $description=~/(ATCC|NCTC|CCUG|DSM|LMG|CIP|NCIB|BCCM|NRRL)\s*([\w-]*)/;
	$cultureCollection = "$cc1 $cc2" if ($cc1 && $cc2);
	
	#($isolateComment) = $description=~/(isolated\s*.*?\S\S\.)/i;
	my ($com1, $com2) = $description=~/(isolated|isolate from|isolate obtained from|derived|is from|was from|came from|recovered from)\s+(.*?\S\S\.)/i;
	$isolateComment = "$com1 $com2";
	$isolateComment =~s/\s*$|\s*\.$//;
	$isolateComment =~s/&lt;|&gt;//g;

	$source = $1 if $isolateComment=~/from\s*(.*)/;
	$source =~s/^(a|an)\s+//;
	$source =~s/( in | by | and will | and is | and is |\s*\.).*//g;
	
	($month, $year) = $isolateComment=~/in\s*([a-zA-Z]*)\s*,*\s+(\d\d\d\d)/;

	($method) = $isolateComment=~/isolated by ([a-z].*)/;
	$method =~s/ (from|in) .*//;

	($person) = $isolateComment=~/isolated by ([A-Z].*)/;
	$person =~s/ (at|in|during) .*//;

	($epidemiology) = $isolateComment=~/(outbreak|epidemic|pandemic)/i;

	$isolateComment=~/(^|\s)(in|in the|at|at the|near|near the)\s([A-Z]+.*)/;	
	$location = $3;
	$location =~s/\..*//;
	
	$location =~s/\W+/ /g;
	$location =~s/^\s*|\s*$|\s\s//g;
	$location =~s/ [a-z0-9]+.*//g;

	my ($num, $unit);
	if ($isolateComment=~/depth of/i){
		($num, $unit) = $isolateComment=~/depth of (\d+\s*[\.\-to]*\s*\d*)\s*(\w+)/; 
		$depth = "$num $unit";
	}elsif($isolateComment=~/below the surface/i){
		($num, $unit) = $isolateComment=~/(\d+\s*[\.\-to]*\s*\d*)\s*(\w+) below the surface/;
		$depth = "$num $unit";
		$depth =~s/\s$//;
	}

	$hostGender = $1 if $isolateComment=~/(male|female)/i;	# man|woman	
	$hostAge = "$1 $2" if $isolateComment=~/(\d+).(year|years|month|months|day|days).old/; # month|months|day|days	

	$hostHealth = $2 if $isolateComment=~/(patient with |suffering from )(.*)/i; # suffered|diagnosed with 
	$hostHealth =~s/^(a|an)\s//;
	$hostHealth =~s/\s+(and is|and will be|and has|and was|by|in|and contains)\s+.*//;

	$hostName = $1 if $isolateComment=~/ (pig|sheep|goat|dog|cat |cattle|chicken|cow|mouse|rat|buffalo|tick|mosquito)/i;
	$hostName ="Homo sapiens" if ($isolateComment=~/ (human|man|woman|infant|child|patient|homo sapiens)/i);


	# Organism Info

	#$genome->{taxon_id} = $taxonID if $taxonID;	
	$genome->{strain} = $strain if $strain;
	$genome->{serovar} = $serovar if $serovar;
	$genome->{biovar} = $biovar if $biovar;
	$genome->{pathovar} = $pathovar if $pathovar;
	$genome->{type_strain} = $typeStrain if $typeStrain;
	$genome->{culture_collection} = $cultureCollection if $cultureCollection;
	$genome->{comments} = $description? $description: "-";
	$genome->{publication} = $publication if $publication;


	# Isolate / Environmental Metadata
	
	#$genome->{isolation_site} = ""; #$source;
	$genome->{isolation_source} = $source if $source;
	$genome->{isolation_comments} = $isolateComment if $isolateComment;
	$genome->{collection_date} = $year if $year;
	#$genome->{isolation_country} = ""; #$location;
	$genome->{geographic_location} = $location if $location;
	#$genome->{latitude} = "";
	#$genome->{longitude} = "";
	#$genome->{altitude} = "";
	#$genome->{depth} = $depth;

	# Host Metadata
	
	$genome->{host_name} = $hostName if $hostName;
	$genome->{host_gender} = $hostGender if $hostGender;
	$genome->{host_age} = $hostAge if $hostAge ;
	$genome->{host_health} = $hostHealth if $hostHealth;
	#$genome->{body_sample_site} = "";
	#$genome->{body_sample_substitute} = "";

}

sub getMetadataFromBioSample {

}


sub getGenomeFeaturesFromGenBankFile {

	my ($genbank_file) = @_;

	my $annotation = "RefSeq";

	my $genomeObj = Bio::SeqIO->new( -file   => "<$genbank_file", -format => 'GenBank');

	while (my $seqObj = $genomeObj->next_seq){

		my ($accession, $sequence_id);

		$accession = $seqObj->accession_number;

		for (my $i=0; $i < scalar @sequences; $i++){
			next unless $sequences[$i]->{accession} eq $accession;
			$sequence_id = $sequences[$i]->{sequence_id}; 
			last;	
		}
	
		for my $featObj ($seqObj->get_SeqFeatures){

			my ($accn, $feature, $pathways, $ecpathways);
			my (@go, @ec_no, @ec, @pathway, @ecpathways, @spgenes, @uniprotkb_accns, @ids);

			$feature->{owner} = $genome->{owner};
			$feature->{public} = $public;
			$feature->{annotation} = $annotation;
			
			$feature->{genome_id} = $genome->{genome_id};
			$feature->{taxon_id} = $genome->{taxon_id};

			$feature->{sequence_id} = $sequence_id;
			$feature->{accession} = $accession;

			$feature->{feature_type} = $featObj->primary_tag;
			$featureIndex->{$feature->{feature_type}}++;

			$feature->{start} = $featObj->start;
			$feature->{end} = $featObj->end;
			$feature->{strand} = ($featObj->strand==1)? '+':'-';
			$feature->{location} = $featObj->location->to_FTstring;

			my @segments;
			if ($featObj->location->isa('Bio::Location::SplitLocationI')){
				for my $location ($featObj->location->sub_Location){
					push @segments, $location->start."..". $location->end;
				}
			}else{
				push @segments, $featObj->start."..". $featObj->end;	
			}
			$feature->{segments} = \@segments;

			$feature->{pos_group} = "$feature->{sequence_id}:$feature->{end}:+" if $feature->{strand} eq '+';
			$feature->{pos_group} = "$feature->{sequence_id}:$feature->{start}:-" if $feature->{strand} eq '-';

			$feature->{na_length} = length($featObj->spliced_seq->seq);
			$feature->{na_sequence} = $featObj->spliced_seq->seq unless $featObj->primary_tag eq "source";

			my $strand = ($feature->{strand} eq '+')? 'fwd':'rev';
			$feature->{feature_id}		=	"$annotation.$feature->{genome_id}.$feature->{accession}.".
																	"$feature->{feature_type}.$feature->{start}.$feature->{end}.$strand";


			for my $tag ($featObj->get_all_tags){

				for my $value ($featObj->get_tag_values($tag)){

					$feature->{feature_type} 	= 'pseudogene' if ($tag eq 'pseudo' && $feature->{feature_type} eq 'gene');

					$feature->{patric_id} = $1 if ($tag eq 'db_xref' && $value=~/SEED:(fig.*)/);					
					$feature->{refseq_locus_tag} 	= $value if ($tag eq 'locus_tag' && $annotation eq "RefSeq");
					$feature->{refseq_locus_tag} 	= $1 if ($tag eq 'db_xref' && $value=~/Refseq_locus_tag:(.*)/i);
					$feature->{protein_id} 	= $value if ($tag eq 'protein_id');
					$feature->{protein_id} 	= $1 if ($tag eq 'db_xref' && $value=~/protein_id:(.*)/);
					$feature->{gene_id} = $1 if ($tag eq 'db_xref' && $value=~/^GeneID:(\d+)/);
					$feature->{gi} = $1 if ($tag eq 'db_xref' && $value=~/^GI:(\d+)/);

					$feature->{aa_sequence} = $value if ($tag eq 'translation');
					$feature->{aa_length} 	= length($value) if ($tag eq 'translation');
					$feature->{aa_sequence_md5} = md5_hex($value) if ($tag eq 'translation');
					
					$feature->{gene} = $value if ($tag eq 'gene');
					$feature->{product} = $value if ($tag eq 'product');

					$feature->{figfam_id} 	= $value if ($tag eq 'FIGfam');
					
					if ($tag eq 'EC_number'){
						my $ec_number = $value;	
						my $ec_description = $ecRef->{$ec_number}->{ec_description};
						push @ec, $ec_number.'|'.$ec_description unless (grep {$_ eq $ec_number.'|'.$ec_description} @ec);
					}

					push @ids, $value if ($tag eq 'db_xref');
				
				}

			}

			$feature->{ec} = \@ec if scalar @ec;
	
			push @features, $feature  unless ($feature->{feature_type} eq 'gene' && (grep {$_=~/Bacteria|Archaea/} @{$genome->{taxon_lineage_names}}));
		
			$genome->{lc($annotation).'_cds'}++ if $feature->{feature_type} eq 'CDS'	

		}

	}

	$genomeObj->close();


}
