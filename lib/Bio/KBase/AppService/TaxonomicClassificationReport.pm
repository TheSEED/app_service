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
    my($task_id, $params, $report_file, $read_set, $output_fh) = @_;

    my $templ = Template->new(ABSOLUTE => 1);
    my $tax_base = 'https://www.patricbrc.org/view/Taxonomy';

    my $rpt = '';
    if (open(R, "<", $report_file))
    {
	while (<R>)
	{
	    chomp;
	    my($pct, $count_clade, $count_taxon, $rank_code, $tax, $name) = split(/\t/);
	    next if ($pct < 1 && $. > 1);
	    if ($tax > 1)
	    {
		my($sp, $txt) = $name =~ /^(\s+)(.*)$/;
		$name = qq($sp<a target="_blank" href="$tax_base/$tax">$txt</a>);
	    }
	    $rpt .= join("\t", $pct, $count_clade, $count_taxon, $rank_code, $tax, $name) . "\n";
	}
    }

    my $vars = {
	job_id => $task_id,
	top_hits => $rpt,
	params => $params,
	read_set => $read_set, 
    };
    write_file("debug", Dumper($vars));
    my $mod_path = Module::Metadata->find_module_by_name(__PACKAGE__);
    my $tt_file = dirname($mod_path) . "/TaxonomicReport.tt";
    $templ->process($tt_file, $vars, $output_fh) || die "Error processing template: " . $templ->error();
    
}

1;


