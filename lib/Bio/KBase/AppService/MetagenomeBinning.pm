
#
# Module to encapsulate metagenome binning code.
#
# Name badness. app_params used in two different ways down there. Fix that.
#

package Bio::KBase::AppService::MetagenomeBinning;

use P3DataAPI;
use gjoseqlib;
use strict;
use Data::Dumper;
use POSIX;
use Cwd;
use base 'Class::Accessor';
use JSON::XS;
use Module::Metadata;
use Bio::KBase::AppService::ClientExt;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name
					 binning_spades_threads binning_spades_ram
					 bebop_binning_user bebop_binning_key
					 seedtk binning_genome_annotation_clientgroup);
use DBI;
use File::Slurp;

use Bio::KBase::AppService::BebopBinning;

push @INC, seedtk . "/modules/RASTtk/lib";
push @INC, seedtk . "/modules/p3_seedtk/lib";
require BinningReports;
require GEO;

__PACKAGE__->mk_accessors(qw(app app_def params token task_id
			     work_dir assembly_dir stage_dir
			     output_base output_folder 
			     assembly_params spades
			     contigs app_params bebop
			    ));

sub new
{
    my($class) = @_;

    my $self = {
	assembly_params => [],
	app_params => [],
    };

    if (bebop_binning_user && bebop_binning_key)
    {
	my $bebop = Bio::KBase::AppService::BebopBinning->new(user => bebop_binning_user,
							       key => bebop_binning_key);
	$self->{bebop} = $bebop;
    }

    return bless $self, $class;
}

#
# Preflight. The CGA app itself has fairly requirements; it spends most of its
# time waiting on other applications.
#
# We don't mark as a control task, however, because it does have some signficant
# cpu use.
#
sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $pf = {
	cpu => 1,
	memory => "64G",
	runtime => 0,
	storage => 0,
	is_control_task => 0,
    };
    return $pf;
}

sub process
{
    my($self, $app, $app_def, $raw_params, $params) = @_;

    $self->app($app);
    $self->app_def($app_def);
    $self->params($params);
    $self->token($app->token);
    $self->task_id($app->task_id);

    print "Process metagenome binning run ", Dumper($app_def, $raw_params, $params);

    my $cwd = getcwd();
    my $assembly_dir = "$cwd/assembly";
    my $work_dir = "$cwd/work";
    my $stage_dir = "$cwd/stage";
    
    -d $work_dir or mkdir $work_dir or die "Cannot mkdir $work_dir: $!";
    -d $assembly_dir or mkdir $assembly_dir or die "Cannot mkdir $assembly_dir: $!";
    -d $stage_dir or mkdir $stage_dir or die "Cannot mkdir $stage_dir: $!";

    $self->work_dir($work_dir);
    $self->assembly_dir($assembly_dir);
    $self->stage_dir($stage_dir);

    my $output_base = $self->params->{output_file};
    my $output_folder = $self->app->result_folder();

    $self->output_base($output_base);
    $self->output_folder($output_folder);

    #
    # Check for exactly one of our input types;
    my @input = grep { $_ } @$params{qw(paired_end_libs contigs srr_ids)};
    if (@input == 0)
    {
	die "No input data specified";
    }
    elsif (@input > 1)
    {
	die "Only one input data item may be specified";
    }

    if (my $val = $params->{paired_end_libs})
    {
	if ($self->bebop)
	{
	    #
	    # Check for new form
	    #
	    
	    if (@$val == 2 && !ref($val->[0]) && !ref($val->[1]))
	    {
		$val = [{ read1 => $val->[0], read2 => $val->[1] }];
	    }
	    
	    if (@$val != 1)
	    {
		die "MetagenomeBinning:: only one paired end library may be provided";
	    }
	    $self->bebop->assemble_paired_end_libs($output_folder, $val->[0], $self->app->task_id);
	    my $local_contigs = "$assembly_dir/contigs.fasta";
	    $self->contigs($local_contigs);
	    print "Copy from " . $self->output_folder . "/contigs.fasta to $local_contigs\n";
	    $app->workspace->download_file($self->output_folder . "/contigs.fasta",
					   $local_contigs,
					   1, $self->token);
	    if (! -f $local_contigs)
	    {
		die "Local data not found\n";
	    }
	}
	else
	{
	    $self->stage_paired_end_libs($val);
	    $self->assemble();
	}
    }
    elsif (my $val = $params->{srr_ids})
    {
	if ($self->bebop)
	{
	    $self->bebop->assemble_srr_ids($val);
	}
	else
	{
	    $self->stage_srr_ids($val);
	    $self->assemble();
	}
    }
    else
    {
	$self->stage_contigs($params->{contigs});
    }

    $self->compute_coverage();
    $self->compute_bins();
    my $all_bins = $self->extract_fasta();

    my $n_bins = @$all_bins;
    if ($n_bins == 0)
    {
	#
	# No bins found. Write a simple HTML stating that.
	#
	my $report = "<h1>No bins found</h1>\n<p>No bins were found in this sample.\n";
	$app->workspace->save_data_to_file($report, {},
					   "$output_folder/BinningReport.html", 'html', 1, 0, $app->token);
	return;
    }

    my $app_service = Bio::KBase::AppService::ClientExt->new();

    my @good_results;

    my $annotations_inline = $ENV{P3_BINNING_ANNOTATIONS_INLINE};
    if ($annotations_inline)
    {
	@good_results = $self->compute_annotations();
    }
    else
    {
	my @tasks;
	if ($ENV{BINNING_TEST})
	{
	    @tasks = qw(0da446f2-8274-45f1-856b-2b06c0d4154e
			5ea8d032-1119-4713-836d-088e13848e2f
			15f43bdf-e1dc-45a8-8a1c-0b4561324d68);
	}
	else
	{
	    @tasks = $self->submit_annotations($app_service);
	} 
	print STDERR "Awaiting completion of $n_bins annotations\n";
	my $results = $app_service->await_task_completion(\@tasks, 10, 0);
	print STDERR "Tasks completed\n";
	
	#
	# Examine task output to ensure all succeeded
	#
	my $fail = 0;
	for my $res (@$results)
	{
	    if ($res->{status} eq 'completed')
	    {
		push(@good_results, $res);
	    }
	    else
	    {
		warn "Task $res->{id} resulted with unsuccessful status $res->{status}\n" . Dumper($res);
		$fail++;
	    }
	}
	
	if ($fail > 0)
	{
	    if ($fail == @$results)
	    {
		die "Annotation failed on all $fail bins\n";
	    }
	    else
	    {
		my $n = @$results;
		warn "Annotation failed on $fail of $n bins, continuing\n";
	    }
	}
    }	
    #
    # Annotations are complete. Pull data and write the summary report.
    #

    $self->write_summary_report(\@good_results, $all_bins, $self->app->workspace, $self->token);
}

#
# Stage the paired end library data as given in parameters. Ensure we
# have a single pair of contigs (spades metagenome assembler only
# handles one pair of paired-end read sets).
#
# 'paired_end_libs' => [
#		                                        '/olson@patricbrc.org/Binning/Data/SRR2188006_1.fastq.gz',
#		                                        '/olson@patricbrc.org/Binning/Data/SRR2188006_2.fastq.gz'
#		                                      ],
    

sub stage_paired_end_libs
{
    my($self, $libs) = @_;

    my @reads;

    #
    # Check for new form
    #

    if (@$libs == 2 && !ref($libs->[0]) && !ref($libs->[1]))
    {
	@reads = @$libs;
    }
    else
    {
	if (@$libs == 0)
	{
	    die "MetagenomeBinning:: stage_paired_end_libs - no libs provided";
	}
	elsif (@$libs > 1)
	{
	    die "MetagenomeBinning:: stage_paired_end_libs - only one lib may be provided";
	}

	my $lib = $libs->[0];
	@reads = @$lib{qw(read1 read2)};
    }
    my $staged = $self->app->stage_in(\@reads, $self->stage_dir, 1);

    push(@{$self->assembly_params},
	 "-1", $staged->{$reads[0]},
	 "-2", $staged->{$reads[1]});
}

#
# Stage the assembled contigs.
#
sub stage_contigs
{
    my($self, $contigs) = @_;

    my $staged = $self->app->stage_in([$contigs], $self->stage_dir, 1);

    my $file = $staged->{$contigs};
    if (my($unzipped) = $file =~ /(.*)\.gz$/)
    {
	print STDERR "Unzipping $file => $unzipped\n";
	my $rc = system("gunzip", $file);
	if ($rc != 0)
	{
	    die "Error unzipping $file: $rc\n";
	}
	elsif (-s $unzipped)
	{
	    $self->contigs($unzipped);
	}
	else
	{
	    die "Zero-length file $unzipped resulting from unzipping $file\n";
	}
    }
    else
    {
	$self->contigs($staged->{$contigs});
    }
}

#
# Invoke the assembler. We've built a list of assembler parameters during
# the stage-in process. Complete the set of parameters for our
# current configuration and run the assembly.
#
sub assemble
{
    my ($self) = @_;

    my $params = $self->assembly_params;
    push(@$params,
	 "--meta",
	 "-o", $self->assembly_dir);

    if (binning_spades_threads)
    {
	push(@$params, "--threads", binning_spades_threads);
    }
    if (binning_spades_ram)
    {
	push(@$params, "--memory", binning_spades_ram);
    }
    
    my @cmd = ($self->spades, @$params);
    my $rc = system(@cmd);
    #my $rc = 0;
    if ($rc != 0)
    {
	die "Error running assembly command: @cmd\n";
    }

    $self->app->workspace->save_file_to_file($self->assembly_dir . "/contigs.fasta", {},
					     $self->output_folder . "/contigs.fasta", 'contigs', 1, 1, $self->token);
    $self->app->workspace->save_file_to_file($self->assembly_dir . "/spades.log", {},
					     $self->output_folder . "/spades.log", 'txt', 1, 1, $self->token);
    $self->app->workspace->save_file_to_file($self->assembly_dir . "/params.txt", {},
					     $self->output_folder . "/params.txt", 'txt', 1, 1, $self->token);

    $self->contigs($self->assembly_dir . "/contigs.fasta");
}

#
# Use bins_coverage to compute coverage. This has a side effect of
# copying the input fasta data to the work directory.
sub compute_coverage
{
    my($self) = @_;

#    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";

    my @cmd = ("bins_coverage",
	       "--statistics-file", "coverage.stats.txt",
	       $self->contigs, $self->work_dir);
    my $rc = system(@cmd);

    $rc == 0 or die "Error $rc running coverage: @cmd";
	
    $self->app->workspace->save_file_to_file("coverage.stats.txt", {},
					     $self->output_folder . "/coverage.stats.txt", 'txt', 1, 1, $self->token);
}

sub compute_bins
{
    my($self) = @_;

#    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";

    my @cmd = ("bins_generate",
	       "--statistics-file", "bins.stats.txt",
	       $self->work_dir);
    my $rc = system(@cmd);

    $rc == 0 or die "Error $rc computing bins: @cmd";
	
    $self->app->workspace->save_file_to_file("bins.stats.txt", {},
					     $self->output_folder . "/bins.stats.txt", 'txt', 1, 1, $self->token);
}

sub extract_fasta
{
    my($self) = @_;

    #my @cmd = ("bins_fasta", $self->work_dir);
    #my $rc = system(@cmd);
    # $rc == 0 or die "Error $rc computing bins: @cmd";

    #
    # We essentially inline the bins_fasta code here since we want
    # to extract the metadata from the bins.json file as we go.
    #

    local $/ = "//\n";
    open(BINS, "<", $self->work_dir . "/bins.json") or die "Cannot open " . $self->work_dir . "/bins.json: $!" ;
    open(SAMPLE, "<", $self->work_dir . "/sample.fasta") or die "Cannot open " . $self->work_dir . "/sample.fasta: $!" ;

    #
    # App params exemplar for annotation submission
    #
    # {
    # "contigs": "/olson@patricbrc.org/home/buchnera.fa",
    #     "scientific_name": "Buchnera aphidicola",
    #     "code": 11,
    #     "domain": "Bacteria",
    #     "taxonomy_id": 107806,
    #     "output_path": "/olson@patricbrc.org/home/output",
    #     "output_file": "buch32"
    #     }

    my $app_list = $self->app_params;

    my $api = P3DataAPI->new(data_api_url);

    my $idx = 1;

    my $all_bins = [];
    while (defined(my $bin_txt = <BINS>))
    {
	chomp $bin_txt;
	my $bin;
	eval { $bin = decode_json($bin_txt); };
	if ($@)
	{
	    warn "Bad parse on '$bin_txt'\n";
	    last;
	}
	push(@$all_bins, $bin);

	my $taxon_id = $bin->{taxonID};
	print "$bin->{name} $taxon_id\n";
	my %want;
	for my $c (@{$bin->{contigs}})
	{
	    $want{$c->[0]} = 1;
	}

	my $bin_base_name = "bin.$idx.$taxon_id";
	my $bin_name = "$bin_base_name.fa";
	$bin->{binFastaFile} = $bin_name;
	$bin->{binIndex} = $idx;
	$idx++;
	my $bin_fa = $self->work_dir . "/$bin_name";
	open(BIN, ">", $bin_fa) or die "Cannot write $bin_fa: $!";
	seek(SAMPLE, 0, 0);

	local $/ = "\n";
	while (my($id, $def, $seq) = read_next_fasta_seq(\*SAMPLE))
	{
	    if ($want{$id})
	    {
		write_fasta(\*BIN, [[$id, $def, $seq]]);
	    }
	}
	close(BIN);

	my $ws_path = $self->output_folder . "/$bin_name";
	$self->app->workspace->save_file_to_file($bin_fa, $bin, $ws_path, 'contigs', 1, 1, $self->token);
	$bin->{binFastaPath} = $ws_path;

	my $code = 11;
	my $domain = 'Bacteria';
	my @res = $api->query("taxonomy", ["eq", 'taxon_id', $taxon_id], ["select", "genetic_code,lineage_names"]);
	if (@res)
	{
	    my $lineage;
	    ($code, $lineage) = @{$res[0]}{'genetic_code', 'lineage_names'};
	    shift @$lineage if ($lineage->[0] =~ /cellular organisms/);
	    $domain = $lineage->[0];
	}

	$bin->{domain} = $domain;
	$bin->{geneticCode} = $code;

	my $descr = {
	    contigs => $ws_path,
	    code => $code,
	    domain => $domain,
	    scientific_name=> $bin->{name},
	    taxonomy_id => $taxon_id,
	    reference_genome_id => $bin->{refGenomes}->[0],
	    output_path => $self->output_folder,
#	    output_path => $self->params->{output_path},
	    output_file => $bin_base_name,
#	    _parent_job => $self->app->task_id,
	    queue_nowait => 1,
	    analyze_quality => 1,
	    ($self->params->{skip_indexing} ? (skip_indexing => 1) : ()),
	    recipe => $self->params->{recipe},
	    (binning_genome_annotation_clientgroup ? (_clientgroup => binning_genome_annotation_clientgroup) : ()),
	};
	push(@$app_list, $descr);
    }
    my $json = JSON::XS->new->pretty(1)->canonical(1);
    $self->app->workspace->save_data_to_file($json->encode($all_bins), {},
					     $self->output_folder . '/bins.json', 'json', 1, 1, $self->token);
    print "SAVE to " . $self->output_folder . "/bins.json\n";

    close(SAMPLE);
    close(BINS);
    print STDERR Dumper($self->app_params);

    #
    # Return the bins so that we can cleanly terminate the job if no bins
    # were found. Also used later for reporting.
    #
    return $all_bins;
}
    
sub write_db_record
{
    my($self, $n_children) = @_;
    
    my $dsn = "DBI:mysql:database=" . db_name . ";host=" . db_host;
    my $dbh = DBI->connect($dsn, db_user, db_pass, { RaiseError => 1, AutoCommit => 0 });

    my $json = JSON::XS->new->pretty(1)->canonical(1);

    $dbh->do(qq(INSERT INTO JobGroup (parent_job, children_created, parent_app, app_spec, app_params)
		VALUES (?, ?, ?, ?, ?)), undef,
	     $self->app->task_id, $n_children, "MetagenomeBinning",
	     $json->encode($self->app_def), $json->encode($self->params));
    $dbh->commit();
}

#
# Compute annotations inline by invoking the annotation script.
# Mostly used for testing, but may be useful for standalone implementation.
#
# Returns a list of Task hashes.
#
sub compute_annotations
{
    my($self) = @_;

    #
    # Need to find our app specs. Different locations if we are in production or development.
    #

    my $app_spec = $self->find_app_spec("GenomeAnnotation");

    my @good_results;

    my $sub_time = time;
    my $n = 1;
    for my $task (@{$self->app_params})
    {
	my $tmp = File::Temp->new;
	print $tmp encode_json($task);
	close($tmp);
	my @cmd = ("App-GenomeAnnotation", "xx", $app_spec, "$tmp");
	# my @cmd = ("bash", "-c", "source /vol/patric3/production/P3Slurm2/tst_deployment/user-env.sh; App-GenomeAnnotation xx $app_spec $tmp");
	print STDERR "Run annotation: @cmd\n";
	my $start = time;
	my $rc = system(@cmd);
	my $end = time;
	if ($rc != 0)
	{
	    warn "Annotation failed with rc=$rc\n";
	    next;
	}
	push(@good_results, {
	    id => $n++,
	    app => "App-GenomeAnnotation",
	    parameters => $task,
	    user_id => 'immediate-user',
	    submit_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $sub_time),
	    start_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $start),
	    completed_time => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime $end),
	});
    }
print Dumper(GOOD => \@good_results);
    return @good_results;
}
    

sub submit_annotations
{
    my($self, $client) = @_;

    if ($ENV{BINNING_PRINT_SUBS})
    {
	my $json = JSON::XS->new->pretty(1)->canonical(1);
	my $i = 1;
	for my $task (@{$self->app_params})
	{
	    open(OUT, ">", "binning.job.$i") or die;
	    print OUT $json->encode($task);
	    close(OUT);
	    $i++;
	}
	exit;
    }

    #
    # No longer needed with new code that waits for annos.
    # $self->write_db_record(scalar @{$self->app_params});

    my $start_params = {
	parent_id => $self->app->task_id,
	workspace => $self->output_folder,
    };
    my @tasks;
    for my $task (@{$self->app_params})
    {
	my $submitted = $client->start_app2("GenomeAnnotation", $task, $start_params);
	push(@tasks, $submitted);
    }
    return @tasks;
}
    

#
# Write the summary. $tasks is the list of annotation tasks from the app service; included therein
# are the parameters to the annotation runs which includes the output locations. Use those to
# pull the genome objects.
#
sub write_summary_report
{
    my($self, $tasks, $bins_report, $ws, $token) = @_;

    my @genomes;
    my @geos;
    my %report_url_map;

    my %geo_opts = (
	detail => 2,
	p3 => P3DataAPI->new(data_api_url, $token->token),
    );
    
    local $FIG_Config::global = seedtk . "/data";
    for my $task (@$tasks)
    {
	my $params = $task->{parameters};
	my $name = $params->{output_file};
	my $genome_path = $params->{output_path} . "/.$name";
	my $gto_path = "$genome_path/$name.genome";

	#
	# we need to convert to GEOs for the binning reports.
	#
	my $temp = File::Temp->new(UNLINK => 1);
	my $qual_temp = File::Temp->new(UNLINK => 1);

	print "$genome_path/genome_quality_details.txt\n";
	eval {
	    $ws->copy_files_to_handles(1, $token,
				       [[$gto_path, $temp],
					]);
	};
	warn "Error copying $gto_path: $@" if $@;
	eval {
	    $ws->copy_files_to_handles(1, $token,
				       [["$genome_path/genome_quality_details.txt", $qual_temp],
					]);
	};
	warn "Error copying $genome_path/genome_quality_details.txt: $@" if $@;
	close($temp);
	close($qual_temp);

	if (! -s "$temp")
	{
	    warn "Could not load $gto_path\n";
	    next;
	}
		
	my $gret = GEO->CreateFromGtoFiles(["$temp"], %geo_opts);
	my($geo) = values %$gret;

	if (-s "$qual_temp")
	{
	    $geo->AddQuality("$qual_temp");
	    write_file("$name.geo", Dumper($geo));
	    push(@geos, $geo);
	}
	else
	{
	    warn "Could not read qual file $genome_path/genome_quality_details.txt\n";
	}
	my $genome_id = $geo->id;
	print "$genome_id: $geo->{name}\n";
	push(@genomes, $genome_id);

	#
	# We assume the report URL is available in the same workspace
	# directory as the genome.
	#
	# The genome is actually in the same subtree as the summary report,
	# so we use a relative path instead of $genome_path.
	#
	my $report_url = ".$name/GenomeReport.html";
	#my $report_url = "https://www.patricbrc.org/workspace$report_path";
	$report_url_map{$genome_id} = $report_url;
    }

    #
    # Write the genome group
    #

    my $params = $self->params;

    my $group_path;
    if (my $group = $params->{genome_group})
    {
	my $home;
	if ($token->token =~ /(^|\|)un=([^|]+)/)
	{
	    my $un = $2;
	    $home = "/$un/home";
	}

	if ($home)
	{
	    $group_path = "$home/Genome Groups/$group";
	    
	    my $group_data = { id_list => { genome_id => \@genomes } };
	    my $group_txt = encode_json($group_data);
	    
	    my $res = $ws->create({
		objects => [[$group_path, "genome_group", {}, $group_txt]],
		permission => "w",
		overwrite => 1,
	    });
	    print STDERR Dumper(group_create => $res);
	}
	else
	{
	    warn "Cannot find home path '$home'\n";
	}
    }
    #
    # Generate the binning report. We need to load the various reports into memory to do this.
    #
    eval {

	#
	# Find template.
	#
	
	my $mpath = Module::Metadata->find_module_by_name("BinningReports");
	$mpath =~ s/\.pm$//;
	
	my $summary_tt = "$mpath/summary.tt";
	-f $summary_tt or die "Summary not found at $summary_tt\n";

	#
	# Read SEEDtk role map.
	#
	my %role_map;
	if (open(R, "<", seedtk . "/data/roles.in.subsystems"))
	{
	    while (<R>)
	    {
		chomp;
		my($abbr, $hash, $role) = split(/\t/);
		$role_map{$abbr} = $role;
	    }
	    close(R);
	}

	my $html = BinningReports::Summary($self->task_id, $params, $bins_report, $summary_tt,
					   $group_path, \@geos, \%report_url_map);

	my $output_path = $params->{output_path} . "/." . $params->{output_file};
	$ws->save_data_to_file($html, {},
			       "$output_path/BinningReport.html", 'html', 1, 0, $token);
    };
    if ($@)
    {
	warn "Error creating final report: $@";
    }

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
