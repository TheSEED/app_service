
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

    my $assembly_input = $ap->extract_params();
    $assembly_input->{output_path} = $self->output_folder;
    $assembly_input->{output_file} = "assembly";

    my $client = Bio::KBase::AppService::Client->new();
    my $task = $client->start_app("GenomeAssembly", $assembly_input, $self->output_folder);
    print "Created task " . Dumper($task);

    my $task_id = $task->{id};
    my $qtask = $self->await_task_completion($client, $task_id);
    print "Queried status: " . Dumper($qtask);
    exit;
}


sub await_task_completion
{
    my($self, $client, $task_id, $query_frequency, $timeout) = @_;

    $query_frequency //= 60;

    my %final_states = map { $_ => 1 } qw(suspend completed user_skipped skipped passed);

    my $end_time;
    if ($timeout)
    {
	my $end_time = time + $timeout;
    }

    my $qtask;
    while (!$end_time || (time < $end_time))
    {
	$qtask = $client->query_tasks([$task_id]);
	print "Queried status: " . Dumper($qtask);
	
	last if $final_states{$qtask->{status}};
	
	sleep($query_frequency);
	undef $qtask;
    }
    return $qtask;
}

1;
