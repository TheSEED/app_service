package Bio::KBase::AppService::TaxonomicClassificationReport;

use strict;
use Data::Dumper;
use URI::Escape;
use File::Basename;
use Template;
use Module::Metadata;
use File::Slurp;

#
# Write the taxonomic classification report.
#

sub write_report
{
    my($task_id, $params, $report_file, $kraken_output_file, $output_fh) = @_;

    my $templ = Template->new(ABSOLUTE => 1);
    my $tax_base = 'https://www.bv-brc.org/view/Taxonomy';

    my $rpt = '';
    #
    # Process the top hits into a table to be rendered in the template.
    #
    my @top_hits;
    if (open(R, "<", $report_file))
    {
	while (<R>)
	{
	    chomp;
	    my($pct, $count_clade, $count_taxon, $rank_code, $tax, $name) = split(/\t/);
	    next if ($pct < 1 && $. > 1);
	    my($sp, $txt) = $name =~ /^(\s+)(.*)$/;
	    $sp =~ s/ /&nbsp;/g;
	    if ($tax > 1)
	    {
		$name = qq($sp<a target="_blank" href="$tax_base/$tax">$txt</a>);
	    }
	    else
	    {
		$name = "$sp$txt";
	    }
	    push(@top_hits, [$pct, $count_clade, $count_taxon, $rank_code, $tax, $name]);
	    # $rpt .= join("\t", $pct, $count_clade, $count_taxon, $rank_code, $tax, $name) . "\n";
	}
    }

    my $vars = {
	job_id => $task_id,
	top_hits => \@top_hits,
	kraken_output_file => basename($kraken_output_file),
	params => $params,
    };
    write_file("debug", Dumper($vars));
    my $mod_path = Module::Metadata->find_module_by_name(__PACKAGE__);
    my $tt_file = dirname($mod_path) . "/TaxonomicReport.tt";
    $templ->process($tt_file, $vars, $output_fh) || die "Error processing template: " . $templ->error();
    
}

1;


