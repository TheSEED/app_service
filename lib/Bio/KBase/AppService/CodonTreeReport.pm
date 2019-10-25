package Bio::KBase::AppService::CodonTreeReport;

use strict;
use Data::Dumper;
use URI::Escape;
use File::Basename;
use Template;
use Module::Metadata;
use File::Slurp;
use P3DataAPI;

#
# Write the codon tree report.
#

sub write_report
{
    my($task_id, $params, $family_list, $genome_list, $tree_svg, $stats, $output_fh) = @_;

    my $templ = Template->new(ABSOLUTE => 1);
    my $tax_base = 'https://www.patricbrc.org/view/Taxonomy';

    # uri_escape('and(keyword("PGF_03074671"),or(keyword("261317.3"),keyword("563178.4")))','"')
    my $genome_keywords = join(",", map { qq(keyword("$_")) } @{$params->{genome_ids}});

    my @fam_list;
    if ($family_list && @$family_list)
    {
	my $api = P3DataAPI->new();
	my @res = $api->query('protein_family_ref',
			      ['in', 'family_id', '(' . join(",", @$family_list) . ')'],
			      ['select', 'family_id,family_product']);
	print STDERR Dumper(\@res);

	my %res;
	
	for my $ent (@res)
	{
	    my $cond = qq(and(keyword("$ent->{family_id}"),or($genome_keywords)));
	    my $link = "https://www.patricbrc.org/view/FeatureList/?" . uri_escape($cond, '"');
	    $ent->{link} = $link;
	    $res{$ent->{family_id}} = $ent;
	}

	@fam_list = map { $res{$_} } @$family_list;
    }

    my $vars = {
	job_id => $task_id,
	tree_svg => $tree_svg,
	params => $params,
	families => \@fam_list,
	statistics => $stats,
	genomes => $genome_list,
    };
    write_file("debug", Dumper($vars));
    my $mod_path = Module::Metadata->find_module_by_name(__PACKAGE__);
    
    my $tt_file = dirname($mod_path) . "/CodonTreeReport.tt";
    $templ->process($tt_file, $vars, $output_fh) || die "Error processing template: " . $templ->error();
    
}

1;


