
#
# Module to encapsulate comprehensive genome analysis code.
#

package Bio::KBase::AppService::ComprehensiveGenomeAnalysis;

use Bio::KBase::AppService::AssemblyParams;
use Bio::KBase::AppService::Client;

use P3DataAPI;
use gjoseqlib;
use strict;
use File::Basename;
use Data::Dumper;
use Cwd;
use base 'Class::Accessor';
use JSON::XS;
use Date::Parse;
use Bio::KBase::AppService::Client;
use Bio::KBase::AppService::AppConfig qw(data_api_url binning_genome_annotation_clientgroup);
use GenomeTypeObject;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Archive::Zip::MemberRead;

__PACKAGE__->mk_accessors(qw(app app_def params token
			     output_base output_folder 
			     contigs app_params
			     assembly_statistics annotation_statistics
			    ));

sub new
{
    my($class) = @_;

    my $self = {
	app_params => [],
	assembly_statistics => {},
	annotation_statistics => {},
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
	$self->contigs($params->{contigs});
	$self->process_contigs();
    }
    elsif ($params->{input_type} eq 'genbank')
    {
	$self->process_genbank();
    }

    #
    # We have our base annotation completed. Run our report.
    #
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
    my $task;

    if ($ENV{CGA_DEBUG})
    {
	$task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
    }
    else
    {
	$task = $client->start_app("GenomeAssembly", $assembly_input, $self->output_folder);
    }

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
    # Download the report zip so we can read the quast report and determine
    # the runs that completed and which was chosen.
    #

    my @assemblies;
    eval {
	my $analysis_base = "${arast_id}_analysis";
	my $analysis_zip = "${analysis_base}.zip";
	my $analysis_path = join("/",$self->output_folder, ".assembly", $analysis_zip);
	$self->app->workspace->download_file($analysis_path, $analysis_zip, 1, $self->token);
	if (! -s $analysis_zip)
	{
	    die "Failed to download $analysis_path to $analysis_zip\n";
	}
    
	my $zip = Archive::Zip->new();
	system("ls", "-l", $analysis_zip);
	$zip->read($analysis_zip) == AZ_OK or die "Cannot read $analysis_zip: $!";
	my $fh = Archive::Zip::MemberRead->new($zip, "$analysis_base/transposed_report.tsv");
	my $hdrs = $fh->getline();
	print STDERR "Report headers from $analysis_path: $hdrs";
	while (my $l = $fh->getline())
	{
	    chomp $l;
	    print "Line: $l\n";
	    my($assembly, @rest) = split(/\t/, $l);
	    $assembly =~ s/_contigs$//;
	    push(@assemblies, $assembly);
	}
    };
    if ($@)
    {
	die "Retrieval and analysis of assembly report failed:\n$@\n";
    }

    #
    # Fill in assembly run stats for the genome object.
    #
    {
	my $chosen_assembly = $assemblies[0];
	my $other_assemblies = join("\t", @assemblies[1..$#assemblies]);
	my $start = str2time($qtask->{start_time});
	my $end = str2time($qtask->{completed_time});
	my $elap = $end - $start;
	$self->assembly_statistics({
	    job_id => $qtask->{id},
	    start_time => $qtask->{start_time},
	    completion_time => $qtask->{completed_time},
	    elapsed_time => $elap,
	    app_name => $qtask->{app},
	    attributes => {
		arast_job_id => $arast_id,
		chosen_assembly => $chosen_assembly,
		other_assemblies => $other_assemblies,
	    },
	    parameters => $qtask->{parameters},
	});
    }

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
    $annotation_input->{analyze_quality} = 1;

    #
    # We don't require a wait for indexing here.
    #
    $annotation_input->{queue_nowait} = 1;

    if (binning_genome_annotation_clientgroup)
    {
	$annotation_input->{_clientgroup} = binning_genome_annotation_clientgroup;
    }


    print "Annotate with " . Dumper($annotation_input);

    my $client = Bio::KBase::AppService::Client->new();

    my $task;
    if ($ENV{CGA_DEBUG})
    {
	$task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
    }
    else
    {
	$task = $client->start_app("GenomeAnnotation", $annotation_input, $self->output_folder);
    }
    
    print "Created task " . Dumper($task);

    my $task_id = $task->{id};
    my $qtask = $self->await_task_completion($client, $task_id);

    if (!$qtask || $qtask->{status} ne 'completed')
    {
	die "ComprehensiveGenomeAnalysis: process_reads failed\n";
    }


    #
    # Fill in annotation run stats for the genome object.
    #
    {
	my $start = str2time($qtask->{start_time});
	my $end = str2time($qtask->{completed_time});
	my $elap = $end - $start;
	my $stats = {
	    job_id => $qtask->{id},
	    start_time => $qtask->{start_time},
	    completion_time => $qtask->{completed_time},
	    elapsed_time => $elap,
	    app_name => $qtask->{app},
	    attributes => {
	    },
	    parameters => $qtask->{parameters},
	};
	$self->annotation_statistics($stats);
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
    my $annotated_file = "annotation-with-stats.genome";
    my $report = $self->output_folder . "/FullGenomeReport.html";
    my $saved_genome = $self->output_folder . "/annotated.genome";

    $self->app->workspace->download_file("$anno_folder/$file", $file, 1, $self->token->token);

    #
    # Load the genome object, augment with the statistics, and write back out.
    #
    my $gto = GenomeTypeObject->new({file => $file});
    $gto->{job_data} = {
	assembly => $self->assembly_statistics,
	annotation => $self->annotation_statistics,
    };
    $gto->destroy_to_file($annotated_file);

    #
    # For the circular viewer, we need the sp_gene load file.
    #
    my $sp_genes = "sp_gene.json";
    $self->app->workspace->download_file("$anno_folder/load_files/$sp_genes", $sp_genes, 1, $self->token->token);

    #
    # Create the subsystem color map used in both the circular viewer and the report itself.
    #

    my $ss_colors = "subsystem_colors.json";

    my $rc = system("p3x-determine-subsystem-colors", "-o", $ss_colors, $annotated_file);
    $rc == 0 or die "p3x-determine-subsystem-colors failed with rc=$rc";
    
    #
    # Create circular viewer data.
    #

    my $stat_tmp = File::Temp->new;
    close($stat_tmp);

    my @cmd = ("p3x-generate-circos",
	       "--truncate-small-contigs",
	       "--truncate-small-contigs-threshold", 300,
	       "--max-contigs", 500,
	       "--truncation-status-file", "$stat_tmp",
	       "--subsystem-colors", $ss_colors,
	       "--specialty-genes", $sp_genes,
	       "--output-png", "circos.png",
	       "--output-svg", "circos.svg",
	       $annotated_file);
    $rc = system(@cmd);
    $rc == 0 or die "Circos build failed with rc=$rc: @cmd";

    my $n_contigs;
    my $n_contigs_drawn;

    my @circos_stat_param;

    if (open(my $fh, "<", "$stat_tmp"))
    {
	my $l = <$fh>;
	if ($l =~ m,^(\d+)/(\d+),)
	{
	    $n_contigs_drawn = $1;
	    $n_contigs = $2;
	    @circos_stat_param = ("--n-contigs" => $n_contigs, "--n-contigs-drawn" => $n_contigs_drawn);
	}
    }

    my $tree_dir = "codon_tree";
    my $tree_ingroup_size = 10;
    
    my($tree_svg, @trees_to_upload) = compute_tree($annotated_file, $tree_dir, $tree_ingroup_size);

    my @tree_param;
    if ($tree_svg)
    {
	@tree_param = ("-t", $tree_svg);
    }

    @cmd = ("create-report",
	    "-i", $annotated_file,
	    @tree_param,
	    @circos_stat_param,
	    "-o", "FullGenomeReport.html",
	    "-c", "circos.svg",
	    "-s", $ss_colors);
    
    print STDERR "@cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Failure rc=$rc creating genome report\n";
    }
    else
    {
	my $ws = $self->app->workspace;
	$ws->save_file_to_file("FullGenomeReport.html", {}, $report, 'html', 
						 1, 1, $self->token->token);
	$ws->save_file_to_file($annotated_file, {}, $saved_genome, 'genome', 
						 1, 1, $self->token->token);
	$ws->save_file_to_file("circos.svg", {}, $self->output_folder . "/circos.svg", 'svg',
			       1, 0, $self->token->token);
	$ws->save_file_to_file("circos.png", {}, $self->output_folder . "/circos.png", 'png',
			       1, 0, $self->token->token);
	$ws->save_file_to_file($ss_colors, {}, $self->output_folder . "/$ss_colors", 'json',
			       1, 0, $self->token->token);
	for my $ent (@trees_to_upload)
	{
	    my($file, $type) = @$ent;
	    #
	    # write to lowercase so we don't obscure our full report, which is upper case
	    # and is intended to lead the list.
	    #
	    my $base = lcfirst(basename($file));
	    $ws->save_file_to_file($file, {}, $self->output_folder . "/$base", $type,
			       1, 0, $self->token->token);
	}

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

sub compute_tree
{
    my($annotated_file, $tree_dir, $tree_ingroup_size) = @_;
    #
    # Compute ingroup and trees.
    #

    my $tree_svg;
    my $ingroup_file = "tree_ingroup.txt";
    my @cmd = ("p3x-compute-genome-ingroup-outgroup",
	    "--method", "mash",
	    "--ingroup-size", $tree_ingroup_size,
	    $annotated_file,
	    $ingroup_file);
    print "@cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Could not compute tree ingroup\n";
	return undef;
    }

    my $max_genes = 5;
    my $max_allowed_dups = 1;
    my $max_genomes_missing = 2;
    my $bootstrap_reps = 100;
    my $n_threads = 4;
    my $exe = "raxmlHPC-PTHREADS-SSE3";
    
    @cmd = ("p3x-build-codon-tree",
	    "--maxGenes", $max_genes,
	    "--maxAllowedDups", $max_allowed_dups,
	    "--maxGenomesMissing", $max_genomes_missing,
	    "--bootstrapReps", $bootstrap_reps,
	    "--raxmlNumThreads", $n_threads,
	    "--outputDirectory", $tree_dir,
	    "--raxmlExecutable", $exe,
	    "--genomeObjectFile", $annotated_file,
	    $ingroup_file);
    print "@cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Error creating tree\n";
	return undef;
    }

    #
    # We have our tree; use figtree to render SVG.
    #
    
    my $nexus_file = "$tree_dir/CodonTree.nex";
    if (! -f $nexus_file)
    {
	warn "Codon tree $nexus_file does not exist";
	return undef;
    }

    $tree_svg = "CodonTree.svg";
    @cmd = ("figtree", "-graphic", "SVG", $nexus_file, $tree_svg);
    $rc = system(@cmd);
    if ($rc != 0)
    {
	warn "Figtree failed with $rc: @cmd\n";
	return undef;
    }

    return($tree_svg,
	   [$tree_svg, 'svg'],
	   [$ingroup_file, 'txt'],
	   [$nexus_file, 'txt'],
	   ["$tree_dir/CodonTree.stats", 'txt'],
	   ["$tree_dir/CodonTree.nwk", 'nwk']);
    
}

1;
