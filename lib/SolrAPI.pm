package SolrAPI;
use strict;
use JSON;
use Data::Dumper;

# my $solr = "https://www.beta.patricbrc.org/api/";

sub new
{
  my ($class, $data_api_url) = @_;

  my $self = {
      data_api_url => $data_api_url,
      json => JSON->new->allow_nonref,
      format => "&http_content-type=application/solrquery+x-www-form-urlencoded&http_accept=application/json&rows=25000",
  };
  
  return bless $self, $class;
}

sub getTaxonLineage {

	my ($self, $taxon_id) = @_;
	my ($lineage_ids, $lineage_names, $lineage_ranks);

	my $core = "taxonomy";
	my $query = "/?q=taxon_id:$taxon_id";
	my $fields = "&fl=lineage_ids,lineage_names,lineage_ranks";

	my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		$lineage_ids = $record->{lineage_ids};
		$lineage_names = $record->{lineage_names}; 
		$lineage_ranks = $record->{lineage_ranks}; 
	}

	return ($lineage_ids, $lineage_names, $lineage_ranks);

}


sub getEC {

	my ($self, $ec_no) = @_;
	my $ec;

	my $core = "enzyme_class_ref";
	my $query = "/?q=ec_number:$ec_no";
	my $fields = "&fl=ec_number,ec_description";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		$ec = $record->{ec_number}.'|'.$record->{ec_description};
	}

	return $ec;

}


sub getGO {

	my ($self, $go_id) = @_;
	my $go;

	my $core = "gene_ontology_ref";
	my $query = "/?q=go_id:\\\"$go_id\\\"";
	my $fields = "&fl=go_id,go_name";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		$go = $record->{go_id}.'|'.$record->{go_name};
	}

	return $go;

}

sub getECGO {

	my ($self, @ec_no) = @_;
	my @ec = ();
	my @go = ();

	my $core = "enzyme_class_ref";
	my $query = "/?q=ec_number:(".join(" OR ", @ec_no).")";
	my $fields = "&fl=ec_number,ec_description,go";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		push @ec, $record->{ec_number}.'|'.$record->{ec_description};
		foreach my $go (@{$record->{go}}){
			push @go, $go unless (grep {$_ eq $go} @go);
		}
	}

	return (\@ec, \@go);

}


sub getECRef {

	my ($self) = @_;
	my $ec;

	my $core = "enzyme_class_ref";
	my $query = "/?q=ec_number:*";
	my $fields = "&fl=ec_number,ec_description,go";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		$ec->{$record->{ec_number}}->{ec_description} = $record->{ec_description};
		$ec->{$record->{ec_number}}->{go} = $record->{go} if $record->{go};
	}

	return $ec;

}


sub getPathways {

  my ($self, @ec_no) = @_;
  my @pathways = ();
  my @ecpathways = ();

  my $core = "pathway_ref";
  my $query = "/?q=ec_number:(".join(" OR ", @ec_no).")";
  my $fields = "&fl=ec_number,ec_description,pathway_id,pathway_name,pathway_class";

  my $resultObj = $self->query_solr($core, $query, $fields);
  
  foreach my $record (@{$resultObj}){
    my $pathway = $record->{pathway_id}.'|'.$record->{pathway_name};
    my $ecpathway = "$record->{ec_number}\t$record->{ec_description}\t$record->{pathway_id}\t$record->{pathway_name}\t$record->{pathway_class}";
    push @pathways, $pathway unless (grep {$_ eq $pathway} @pathways);
    push @ecpathways, $ecpathway unless (grep {$_ eq $ecpathway} @ecpathways);
  }

  return (\@pathways, \@ecpathways);

}


sub getPathwayRef {

	my ($self) = @_;
	my $pathways = ();

	my $core = "pathway_ref";
	my $query = "/?q=ec_number:*";
	my $fields = "&fl=ec_number,ec_description,pathway_id,pathway_name,pathway_class";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		my $ec_no = $record->{ec_number};
		my $pathway = "$record->{pathway_id}\t$record->{pathway_name}\t$record->{pathway_class}";
		push @{$pathways->{$ec_no}->{pathway}}, $pathway unless (grep {$_ eq $pathway} @{$pathways->{$ec_no}->{pathway}})
	}

	return $pathways;

}


sub getSpGeneInfo {

	my ($self, $source, $source_id) = @_;
	my $spgeneinfo;

	my $core = "sp_gene_ref";
	my $query = "/?q=source:$source AND source_id:$source_id";
	my $fields = "&fl=property,locus_tag,organism,function,classification,pmid,assertion";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		$spgeneinfo = "$record->{property}\t$record->{locus_tag}\t$record->{organism}"
									."\t$record->{function}\t";
		$spgeneinfo .= join(',', @{$record->{classification}}) if $record->{classification};
		$spgeneinfo .= "\t$record->{pmid}\t$record->{assertion}";
	}

	return $spgeneinfo;

}


sub getSpGeneRef {

	my ($self) = @_;
	my $spgenes;

	my $core = "sp_gene_ref";
	my $query = "/?q=source:*";
	my $fields = "&fl=source,source_id,property,locus_tag,organism,function,classification,pmid,assertion";
	
	my $start = 0; 
	while ($start < 200000){
		my $resultObj = $self->query_solr($core, $query, $fields, $start);

		foreach my $record (@{$resultObj}){
			my $key = $record->{source}.'_'.$record->{source_id}; 
			$spgenes->{$key} = "$record->{property}\t$record->{locus_tag}\t$record->{organism}"
									."\t$record->{function}\t";
			$spgenes->{$key} .= join(',', @{$record->{classification}}) if $record->{classification};
			$spgenes->{$key} .= "\t$record->{pmid}\t$record->{assertion}";
		}
		$start = $start + 25000;
	}

	return $spgenes;

}


sub getUniprotkbAccns {

	my ($self, $id_type, $id) = @_;
	my @accns = ();

	my $core = "id_ref";
	my $query = "/?q=id_type:$id_type+AND+id_value:$id";
	my $fields = "&fl=uniprotkb_accession";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		push @accns, $record->{uniprotkb_accession};
	}

	return @accns;

}


sub getIDs {

	my ($self, @accns) = @_;
	my @ids = ();

	my $core = "id_ref";
	my $query = "/?q=uniprotkb_accession:(". join(" OR ", @accns). ")";
	my $fields = "&fl=id_type,id_value";

        my $resultObj = $self->query_solr($core, $query, $fields);

	foreach my $record (@{$resultObj}){
		my $id_str = $record->{id_type}.'|'.$record->{id_value};
		push @ids, $id_str
			unless ($record->{id_type}=~/GI|GeneID|EnsemblGenome|EnsemblGenome_PRO|EnsemblGenome_TRS|PATRIC|EMBL|EMBL-CDS|KEGG|BioCyc|NCBI_TaxID|RefSeq_NT/ || (grep {$_ eq $id_str} @ids) );
	}

	return @ids;
}

sub query_rest
{
    my($self, $path) = @_;
    
    my $url = $self->{data_api_url};
    
    my $solrQ = $url . $path;
    print STDERR "$solrQ\n";

    my($fh, $result);
    if (!open($fh, "-|", "curl", "-s", "-k", $solrQ))
    {
	die "Error $! retrieving $solrQ";
    }
    else
    {
	local $/;
	undef $/;
	$result = <$fh>;
	close($fh);
    }

    eval {
	my $resultObj = decode_json($result);
	return $resultObj;
    };
    if ($@)
    {
	warn "JSON parse failed '$@' on query $solrQ:\n$result\n";
	return undef;
    }
}

sub query_solr
{
    my($self, $core, $query, $fields, $start) = @_;
    my $fh;
    my $result;

    my $url = $self->{data_api_url};
    $url .= '/' unless $url =~ m,/$,;
    
    my $solrQ = join("",
		     $url,
		     $core,
		     $query,
		     $fields,
		     $self->{format},
		     (defined($start) ? "&start=$start" : ()));

    print STDERR "$solrQ\n";

    if (!open($fh, "-|", "curl", "-s", "-k", $solrQ))
    {
	die "Error $! retrieving $solrQ";
    }
    else
    {
	local $/;
	undef $/;
	$result = <$fh>;
	close($fh);
    }
    
    my $resultObj = decode_json($result);
    return $resultObj;
}

1;
