
#
# Module to encapsulate comprehensive genome analysis code.
#

package Bio::KBase::AppService::ComprehensiveGenomeAnalysis;

use Bio::KBase::AppService::AssemblyParams;
use Bio::KBase::AppService::Client;

use P3DataAPI;
use gjoseqlib;
use strict;
use Data::Dumper;
use Cwd;
use base 'Class::Accessor';
use JSON::XS;
use Bio::KBase::AppService::Client;
use Bio::KBase::AppService::AppConfig qw(data_api_url);
use GenomeTypeObject;


__PACKAGE__->mk_accessors(qw(app app_def params token
			     output_base output_folder 
			     contigs app_params
			    ));

sub new
{
    my($class) = @_;

    my $self = {
	assembly_params => [],
	app_params => [],
    };
    return bless $self, $class;
}

sub run
{
    my($self, $app, $app_def, $raw_params, $params) = @_;

    $self->app($app);
    $self->app_def($app_def);
    $self->params($params);
    $self->token($app->token);

    print "Process comprehensive analysis ", Dumper($app_def, $raw_params, $params);

    my $cwd = getcwd();

    my $output_base = $self->params->{output_file};
    my $output_folder = $self->app->result_folder();

    $self->output_base($output_base);
    $self->output_folder($output_folder);

    goto x;

    if ($params->{input_type} eq 'reads')
    {
	$self->process_reads();
	$self->process_contigs();
    }
    elsif ($params->{input_type} eq 'contigs')
    {
	$self->process_contigs();
    }
    elsif ($params->{input_type} eq 'genbank')
    {
	$self->process_genbank();
    }

    #
    # We have our base annotation completed. Run our report.
    #
 x:
    $self->generate_report();
}

#
# Process read files by submitting to assembly service.
#
# We create an AssemblyParams to validate our parameters.
#
sub process_reads
{
    my($self) = @_;

    my $ap = Bio::KBase::AppService::AssemblyParams->new($self->params);

    #
    # Extract the assembly-related parameters, and set the desired
    # output location.
    #

    my $assembly_input = $ap->extract_params();
    $assembly_input->{output_path} = $self->output_folder;
    $assembly_input->{output_file} = "assembly";

    my $client = Bio::KBase::AppService::Client->new();
#    my $task = $client->start_app("GenomeAssembly", $assembly_input, $self->output_folder);

    my $task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
    print "Created task " . Dumper($task);

    my $task_id = $task->{id};
    my $qtask = $self->await_task_completion($client, $task_id);

    if (!$qtask || $qtask->{status} ne 'completed')
    {
	die "ComprehensiveGenomeAnalysis: process_reads failed\n";
    }

    #
    # We have completed. Find the workspace path for the generated contigs and
    # store in our object.
    #
    # Open the job result file to find our assembly job id; from that we can
    # reliably find the analysis data.
    #

    my $result_path = join("/", $self->output_folder, "assembly");
    my $asm_result = $self->app->workspace->download_json($result_path, $self->token);

    my $arast_id = $asm_result->{job_output}->{arast_job_id};

    #
    # Report is named by the arast id.
    #

    my $report_path = join("/",$self->output_folder, ".assembly", "${arast_id}_analysis.zip");

    #
    # But maulik isn't interested in this data so we'll skip it.
    #

    #
    # Determine our contigs location.
    my $contigs_path = join("/", $self->output_folder, ".assembly", "contigs.fa");
    my $stats = $self->app->workspace->get({ objects => [$contigs_path] , metadata_only => 1});

    if (@$stats == 0)
    {
	die "Could not find generated contigs in $contigs_path\n";
    }
    $stats = $stats->[0]->[0];

    print STDERR "Setting contigs to assembled contigs at $contigs_path\n";
    $self->contigs($contigs_path);
}

sub process_contigs
{
    my($self) = @_;

    #
    # Extract the annotation-related parameters, and set the desired
    # output location.
    #

    my $params = $self->params;
    my @keys = qw(contigs scientific_name taxonomy_id code domain workflow analyze_quality);

    my $annotation_input = { map { exists $params->{$_} ? ($_, $params->{$_}) : () } @keys };

    $annotation_input->{output_path} = $self->output_folder;
    $annotation_input->{output_file} = "annotation";
    $annotation_input->{contigs} = $self->contigs;

    print "Annotate with " . Dumper($annotation_input);

    my $client = Bio::KBase::AppService::Client->new();
    my $task = $client->start_app("GenomeAnnotation", $annotation_input, $self->output_folder);

    # my $task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
    print "Created task " . Dumper($task);

    my $task_id = $task->{id};
    my $qtask = $self->await_task_completion($client, $task_id);

    if (!$qtask || $qtask->{status} ne 'completed')
    {
	die "ComprehensiveGenomeAnalysis: process_reads failed\n";
    }

}
    
sub generate_report
{
    my($self) = @_;

    #
    # Download the generated genome object.
    #
    
    my $anno_folder = $self->output_folder . "/.annotation";
    my $file = "annotation.genome";
    my $report = $self->output_folder . "/FullGenomeReport.html";

    $self->app->workspace->download_file("$anno_folder/$file", $file, 1, $self->token->token);

    my $rc = system("create-report", "-i", $file, "-o", "FullGenomeReport.html");
    if ($rc != 0)
    {
	warn "Failure rc=$rc creating genome report\n";
    }
    else
    {
	$self->app->workspace->save_file_to_file($file, {}, $report, 'html', 
						 1, 1, $self->token->token);
    }
    
}

sub await_task_completion
{
    my($self, $client, $task_id, $query_frequency, $timeout) = @_;

    $query_frequency //= 10;

    my %final_states = map { $_ => 1 } qw(failed suspend completed user_skipped skipped passed);

    my $end_time;
    if ($timeout)
    {
	my $end_time = time + $timeout;
    }

    my $qtask;
    while (!$end_time || (time < $end_time))
    {
	my $qtasks = $client->query_tasks([$task_id]);
	$qtask = $qtasks->{$task_id};
	my $status = $qtask->{status};
	print "Queried status = $status: " . Dumper($qtask);
	
	last if $final_states{$status};
	
	sleep($query_frequency);
	undef $qtask;
    }
    return $qtask;
}

1;
