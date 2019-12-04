
#
# Module to encapsulate comprehensive genome analysis code.
#

package Bio::KBase::AppService::ComprehensiveGenomeAnalysis;

use Carp::Always;

use Bio::KBase::AppService::AssemblyParams;
use Bio::KBase::AppService::Client;

use P3DataAPI;
use gjoseqlib;
use POSIX;
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

#
# Preflight. The CGA app itself has low requirements; it spends most of its
# time waiting on other applications.
# Mark it a control task in the preflight.
#
sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $pf = {
	cpu => 1,
	memory => "10G",
	runtime => 0,
	storage => 0,
	is_control_task => 1,
    };
    return $pf;
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
    elsif ($params->{input_type} eq 'gto')
    {
	$self->process_gto();
    }

    #
    # We have our base annotation completed. Run our report.
    #
    print "Generate report\n";
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

    my $inline = $ENV{P3_CGA_TASKS_INLINE};
    my $assembly_app = "GenomeAssembly2";

    my $qtask;
    if ($inline)
    {
	my $app_spec = $self->find_app_spec($assembly_app);
	my $tmp = File::Temp->new();
	print $tmp encode_json($assembly_input);
	close($tmp);

	my @cmd = ("App-$assembly_app", "xx", $app_spec, $tmp);
	
	print STDERR "inline assemble: @cmd\n";

	my $start = time;
	# my $rc = system(@cmd);
	my $rc = 0;
	my $end = time;
	if ($rc != 0)
	{
	    die "Inline assembly failed with rc=$rc\n";
	}

	$qtask = {
	    id => "assembly_$$",
	    app => $assembly_app,
	    parameters => $assembly_input,
	    user_id => 'inline_user',
	    submit_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $start),
	    start_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $start),
	    completed_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $end),
	};
    }
    else
    {
	if ($ENV{CGA_DEBUG})
	{
	    $task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
	}
	else
	{
	    $task = $client->start_app("GenomeAssembly2", $assembly_input, $self->output_folder);
	}
	
	print "Created task " . Dumper($task);
	
	my $task_id = $task->{id};
	$qtask = $self->await_task_completion($client, $task_id);
	
	if (!$qtask || $qtask->{status} ne 'completed')
	{
	    die "ComprehensiveGenomeAnalysis: process_reads failed\n";
	}
    }

    #
    # We have completed. Find the workspace path for the generated contigs and
    # store in our object.
    #

    my @assemblies;
    my $run_details;
    eval {

	my $result_path = join("/", $self->output_folder, ".assembly");
	my $run_details = $self->app->workspace->download_json("$result_path/details/assembly_run_details.json");
	
	#
	# Quast report path is named in the details.
	#
	my $tsv_path = $run_details->{quast_transposed_tsv};
	my $tsv_txt = $self->app->workspace->download_file_to_string("$result_path/$tsv_path", $self->token);

	print STDERR Dumper(T=>$tsv_txt);
	my $fh;
	open($fh, "<", \$tsv_txt) or die "Cannot open quast txt\n";
	my $hdrs = <$fh>;
	print STDERR "Report headers from $tsv_path: $hdrs";
	while (my $l = <$fh>)
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
		chosen_assembly => $qtask->{parameters}->{recipe},
	    },
	    parameters => $qtask->{parameters},
	    run_details => $run_details,
	});
    }

    #
    # Determine our contigs location.
    my $contigs_path = join("/", $self->output_folder, ".assembly", "assembly_contigs.fasta");

    my $stats = eval { $self->app->workspace->get({ objects => [$contigs_path] , metadata_only => 1}) };

    if (!$stats || @$stats == 0)
    {
	die "Could not find generated contigs in $contigs_path ($@)\n";
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
    my @keys = qw(contigs scientific_name taxonomy_id code domain workflow analyze_quality skip_indexing);

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

    my $annotation_app = "GenomeAnnotation";
    my $qtask;
    if ($ENV{P3_CGA_TASKS_INLINE})
    {
	my $app_spec = $self->find_app_spec($annotation_app);
	my $tmp = File::Temp->new();
	print $tmp encode_json($annotation_input);
	close($tmp);

	my @cmd = ("App-$annotation_app", "xx", $app_spec, $tmp);
	
	print STDERR "inline annotate: @cmd\n";

	my $start = time;
	#my $rc = system(@cmd);
	# my $rc = system("bash", "-c", "source /vol/patric3/production/P3Slurm2/tst_deployment/user-env.sh; @cmd");
	my $rc = 0;
	my $end = time;
	if ($rc != 0)
	{
	    die "Inline annotation failed with rc=$rc\n";
	}

	$qtask = {
	    id => "annotation_$$",
	    app => $annotation_app,
	    parameters => $annotation_input,
	    user_id => 'inline_user',
	    submit_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $start),
	    start_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $start),
	    completed_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $end),
	};
    }
    else
    {
	my $client = Bio::KBase::AppService::Client->new();
	
	my $task;
	if ($ENV{CGA_DEBUG})
	{
	    $task = {id => "0941e63f-7812-4602-98f2-858728e1e0d9"};
	}
	else
	{
	    $task = $client->start_app($annotation_app, $annotation_input, $self->output_folder);
	}
	
	print "Created task " . Dumper($task);
	
	my $task_id = $task->{id};
	$qtask = $self->await_task_completion($client, $task_id);
	
	if (!$qtask || $qtask->{status} ne 'completed')
	{
	    die "ComprehensiveGenomeAnalysis: process_reads failed\n";
	}
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
    
sub process_gto
{
    my($self) = @_;

    #
    # Extract the annotation-related parameters, and set the desired
    # output location.
    #

    my $params = $self->params;

    my $gto_ws = $params->{gto};

    print "Create " . $self->output_folder . "/.annotation\n";
    eval { $self->app->workspace->create({ objects => [[$self->output_folder . "/.annotation", 'folder' ]]}); };
    print STDERR "Copy $gto_ws to " .  $self->output_folder . "/.annotation/annotation.genome\n";
    $self->app->workspace->copy({ objects => [[$gto_ws, $self->output_folder . "/.annotation/annotation.genome"]]});
    print STDERR "copy done\n";
    $self->annotation_statistics({});
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
    eval {
	$self->app->workspace->download_file("$anno_folder/load_files/$sp_genes", $sp_genes, 1, $self->token->token);
    };

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
	       (-s $sp_genes ? ("--specialty-genes", $sp_genes) : ()),
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
	chomp $l;
	print STDERR "p3x-generate-circos generated truncation statistics: '$l'\n";
	if ($l =~ m,^(\d+)/(\d+),)
	{
	    $n_contigs_drawn = $1;
	    $n_contigs = $2;
	    @circos_stat_param = ("--n-contigs" => $n_contigs, "--n-contigs-drawn" => $n_contigs_drawn);
	}
    }
    else
    {
	print STDERR "p3x-generate-circos did not generate truncation statistics\n";
    }

    my $tree_dir = "codon_tree";
    my $tree_ingroup_size = 10;
    
    my($tree_svg, @trees_to_upload) = compute_tree($annotated_file, $tree_dir, $tree_ingroup_size);

    my @tree_param;
    if (-s $tree_svg)
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
    
    print STDERR "Creating report with command: @cmd\n";

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

    my %final_states = map { $_ => 1 } qw(failed suspend completed user_skipped skipped passed deleted);

    my $end_time;
    if ($timeout)
    {
	my $end_time = time + $timeout;
    }

    my $qtask;
    while (!$end_time || (time < $end_time))
    {
	my $qtasks = eval { $client->query_tasks([$task_id]); };
	if ($@)
	{
	    warn "Error checking tasks: $@\n";
	}
	else
	{
	    $qtask = $qtasks->{$task_id};
	    my $status = $qtask->{status};
	    print "Queried status = $status: " . Dumper($qtask);
	    
	    last if $final_states{$status};
	}
	
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
	die "Could not compute tree ingroup\n";
    }

    my $max_genes = 5;
    my $max_allowed_dups = 1;
    my $max_genomes_missing = 2;
    my $bootstrap_reps = 100;
    my $n_threads = $ENV{P3_ALLOCATED_CPU} // 2;

    my $exe = "raxmlHPC-PTHREADS-SSE3";
    
    @cmd = ("p3x-build-codon-tree",
	    "--maxGenes", $max_genes,
	    "--maxAllowedDups", $max_allowed_dups,
	    "--maxGenomesMissing", $max_genomes_missing,
	    "--bootstrapReps", $bootstrap_reps,
	    "--threads", $n_threads,
	    "--outputDirectory", $tree_dir,
	    "--raxmlExecutable", $exe,
	    "--genomeObjectFile", $annotated_file,
	    "--genomeIdsFile", $ingroup_file);
    print "@cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	die "Error creating tree\n";
    }

    #
    # We have our tree; use figtree to render SVG.
    #
    
    my $nexus_file = "$tree_dir/detail_files/codontree.nex";
    if (! -f $nexus_file)
    {
	die "Codon tree $nexus_file does not exist";
    }

    $tree_svg = "CodonTree.svg";
    @cmd = ("figtree", "-graphic", "SVG", $nexus_file, $tree_svg);
    $rc = system(@cmd);
    if ($rc != 0)
    {
	die "Figtree failed with $rc: @cmd\n";
    }

    return($tree_svg,
	   [$tree_svg, 'svg'],
	   [$ingroup_file, 'txt'],
	   [$nexus_file, 'txt'],
	   (map { [$_, 'txt'] } <$tree_dir/detail_files/*.txt>),
	   (map { [$_, 'nwk'] } <$tree_dir/*.nwk>),
	   );
    
}

sub find_app_spec
{
    my($self, $app) = @_;
    
    my $top = $ENV{KB_TOP};
    my $specs_deploy = "$top/services/app_service/app_specs";
    my $specs_dev = "$top/modules/app_service/app_specs";
    my $specs;
    
    if (-d $specs_deploy)
    {
	$specs = $specs_deploy
    }
    elsif (-d $specs_dev)
    {
	$specs = $specs_dev
    }
    else
    {
	die "cannot find specs file in $specs_deploy or $specs_dev\n";
    }
    my $app_spec = "$specs/$app.json";
    -f $app_spec or die "Spec file $app_spec does not exist\n";
    return $app_spec;
}

1;
