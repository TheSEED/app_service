#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;
use Bio::P3::Workspace::WorkspaceClient;
use strict;
use Data::Dumper;
use gjoseqlib;

use Bio::KBase::GenomeAnnotation::GenomeAnnotationImpl;
use Bio::KBase::GenomeAnnotation::Service;

my $get_time = sub { time, 0 };
eval {
    require Time::HiRes;
    $get_time = sub { Time::HiRes::gettimeofday };
};

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

$script->run(\@ARGV);

sub process_genome
{
    my($app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $svc = Bio::KBase::GenomeAnnotation::Service->new();
    
    my $ctx = Bio::KBase::GenomeAnnotation::ServiceContext->new($svc->{loggers}->{userlog},
								client_ip => "localhost");
    $ctx->module("App-GenomeAnnotation");
    $ctx->method("App-GenomeAnnotation");
    my $token = Bio::KBase::AuthToken->new(ignore_authrc => 1);
    if ($token->validate())
    {
	$ctx->authenticated(1);
	$ctx->user_id($token->user_id);
	$ctx->token($token->token);
    }
    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $ctx;
    my $stderr = Bio::KBase::GenomeAnnotation::ServiceStderrWrapper->new($ctx, $get_time);
    $ctx->stderr($stderr);

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


    $ctx->stderr(undef);
    undef $stderr;
}
