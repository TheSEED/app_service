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
	scientific_name => $params->{scientific_name},
	genetic_code => $params->{code},
	domain => $params->{domain},
    };
    my $genome = $impl->create_genome($meta);

    my $ws = Bio::P3::Workspace::WorkspaceClient->new();

    my($input_path, $obj) = $params->{contigs} =~ m,^(.*)/([^/]+)$,;

    #
    # Default the output values based on the input.
    #
    my $output_path = $params->{output_path};
    my $output_base = $params->{output_file};

    if (!$output_path)
    {
	$output_path = $input_path;
    }
    if (!$output_base)
    {
	$output_base = $obj;
	$output_base =~ s/\.([^.]+)$//;
    }
    
    my $res = $ws->get_objects({ objects => [[$input_path, $obj]] });

    if (ref($res) ne 'ARRAY' || @$res == 0 || !$res->[0]->{data})
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

    my @objs;

    $ws->save_objects({ objects => [[$output_path, "$output_base.genome", $result, "Genome"]], overwrite => 1 });

    for my $format (qw(genbank genbank_merged feature_data protein_fasta contig_fasta feature_dna gff embl))
    {
	my $exp = $impl->export_genome($result, $format, []);
	$ws->save_objects({ objects => [[$output_path, "$output_base.$format", $exp, "String"]], overwrite => 1});
    }
}
