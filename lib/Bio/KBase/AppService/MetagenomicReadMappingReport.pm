package Bio::KBase::AppService::MetagenomicReadMappingReport;

use strict;
use Data::Dumper;
use URI::Escape;
use File::Basename;
use Template;
use Module::Metadata;
use File::Slurp;

use base qw(Exporter);
our @EXPORT_OK = qw(write_report);

#
# Write the read mapping report
#
# $output_base is the path including output prefix to which the kma output is written.
#
# Thus we have output files $output_base.fsa, $output_base.res, etc.
#

sub write_report
{
    my($task_id, $params, $output_base, $output_fh) = @_;

    my $templ = Template->new(ABSOLUTE => 1);
    my $tax_base = 'https://www.patricbrc.org/view/Taxonomy';
    my $genome_base = 'https://www.patricbrc.org/view/GenomeList';
    my $special_genes_base = 'https://www.patricbrc.org/view/SpecialtyGeneList';

    my @res;
    my @res_hdr;
    if (open(R, "<", "$output_base.res"))
    {
	$_ = <R>;
	chomp;
	@res_hdr = split(/\t/, $_);
	s/^\#// foreach @res_hdr;
	s/_/ /g foreach @res_hdr;
	@res_hdr = ($res_hdr[0], 'Function', 'Genome', @res_hdr[1..$#res_hdr]);
	while (<R>)
	{
	    chomp;
	    my $row = [];
	    my @val = split(/\t/);
	    my $key = shift @val;
	    my $link;
	    my $function;
	    my $genome;
	    my $glink;
	    my $id = $key;
	    if ($key =~ s/^(\S+)\s+//)
	    {
		$id = $1;
		if ($id =~ /(CARD|VFDB)\|(.*)/)
		{
		    $link = "$special_genes_base/?eq(source_id,$2)";
		}
		if ($key =~ /^\s*(.*)\s+\[([^]]+)\]$/)
		{
		    $function = $1;
		    $genome = $2;
		    $glink = "$genome_base/?eq(genome_name," . uri_escape($genome) . ")";
		}
	    }
	    
	    push(@$row,
	     { key => $id, link => $link },
	     { key => $function },
	     { key => $genome, link => $glink });
	    push @$row, map { { key => $_ } } @val;
	    push @res, $row;
	}
    }

    my $vars = {
	job_id => $task_id,
	params => $params,
	results => \@res,
	results_header => \@res_hdr,
    };
    write_file("debug", Dumper($vars));
    my $mod_path = Module::Metadata->find_module_by_name(__PACKAGE__);
    my $tt_file = dirname($mod_path) . "/MetagenomicReadMappingReport.tt";
    $templ->process($tt_file, $vars, $output_fh) || die "Error processing template: " . $templ->error();
    
}

1;


