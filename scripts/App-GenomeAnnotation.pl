#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use Bio::P3::Workspace::WorkspaceClient;
use strict;
use Data::Dumper;
use gjoseqlib;

use Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl;

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

$script->run(\@ARGV);

sub process_genome
{
    my($app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $impl = Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl->new();

    my $meta = {
	scientific_name => $params->{species},
	genetic_code => $params->{code},
	domain => $params->{domain},
    };
    my $genome = $impl->create_genome($meta);

    my $ws = Bio::P3::Workspace::WorkspaceClient->new();

    my($path, $obj) = $params->{contigs} =~ m,^(.*)/([^/]+)$,;
    my $res = $ws->get_objects({ objects => [[$path, $obj]] });

    if (ref($res) ne 'ARRAY' || @$res == 0)
    {
	die "Could not get contigs object\n";
    }

    my $h = \$res->[0]->{data} ;
    open(FH, "<", $h);
    while (my($id, $def, $seq) = gjoseqlib::read_next_fasta_seq(\*FH))
    {
	$impl->add_contigs($genome, [{ id => $id, dna => $seq }]);
    }
    close(FH);

    my $workflow = $impl->default_workflow();
    my $result = $impl->run_pipeline($genome, $workflow);

    my($outpath, $outobj) = $params->{genome} =~ m,^(.*)/([^/]+)$,;

    my $res = $ws->save_objects({ objects => [[$outpath, $outobj, $genome, "Genome"]],
				  overwrite => 1});
    print Dumper($res);
}
