#
# The Genome Annotation application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::GenomeAnnotationCore;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name seedtk);
use IPC::Run;
use SolrAPI;
use DBI;

use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use File::Temp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run;
use IO::File;
use Module::Metadata;
use GenomeTypeObject;

push @INC, seedtk . "/modules/kernel/lib";
require BinningReports;

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome);

my $rc = $script->run(\@ARGV);

exit $rc;

sub process_genome
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $json = JSON::XS->new->pretty(1)->canonical(1);

    #
    # Do some sanity checking on params.
    #
    # Both recipe and workflow may not be specified.
    #
    if ($params->{workflow} && $params->{recipe})
    {
	die "Both a workflow document and a recipe may not be supplied to an annotation request";
    }

    my $core = Bio::KBase::AppService::GenomeAnnotationCore->new(app => $app,
								 app_def => $app_def,
								 params => $params);

    if (exists($raw_params->{tax_id}) && !exists($params->{taxonomy_id}))
    {
	print STDERR "Fixup incorrect taxid in parameters\n";
	$params->{taxonomy_id} = $raw_params->{tax_id};
    }

    my $user_id = $core->user_id;

    #
    # Construct genome object metadata and create a new genome object.
    #

    my $meta = {
	scientific_name => $params->{scientific_name},
	genetic_code => $params->{code},
	domain => $params->{domain},
	($params->{taxonomy_id} ? (ncbi_taxonomy_id => $params->{taxonomy_id}) : ()),
	($user_id ? (owner => $user_id) : ()),

    };
    my $genome = $core->impl->create_genome($meta);

    #
    # Determine workspace paths for our input and output
    #

    my $ws = $app->workspace();

    my($input_path) = $params->{contigs};

    my $output_folder = $app->result_folder();

    my $output_base = $params->{output_file};

    if (!$output_base)
    {
	$output_base = basename($input_path);
    }

    #
    # Read contig data
    #

    my $temp = File::Temp->new();

    $ws->copy_files_to_handles(1, $core->token, [[$input_path, $temp]]);
    
    my $contig_data_fh;
    close($temp);
    open($contig_data_fh, "<", $temp) or die "Cannot open contig temp $temp: $!";

    #
    # Read first block to see if this is a gzipped file.
    #
    my $block;
    $contig_data_fh->read($block, 256);
    if ($block =~ /^\037\213/)
    {
	#
	# Gzipped. Close and reopen from gunzip.
	#
	
	close($contig_data_fh);
	undef $contig_data_fh;
	open($contig_data_fh, "-|", "gzip", "-d", "-c", "$temp") or die "Cannot open gzip from $temp: $!";
    }
    else
    {
	$contig_data_fh->seek(0, 0);
    }
    
    my $n = 0;
    while (my($id, $def, $seq) = gjoseqlib::read_next_fasta_seq($contig_data_fh))
    {
	$core->impl->add_contigs($genome, [{ id => $id, dna => $seq }]);
	$n++;
    }
    close(FH);

    if ($n == 0)
    {
	die "No contigs loaded from $temp $input_path\n";
    }


    #
    # Checkm analysis.
    #
    # Ideally this would be handled by a fork-and-join syntax in the workflow
    # specification but that is a larger project. Here we will simply fork
    # off the checkm analysis to run in parallel. When the main annotation
    # completes, wait for checkm to complete and use the merge_checkm_analysis
    # method to integrate the output into the genome object.
    #
    # We will also copy the output directory from checkm into the genome
    # annotation output for future reference in the event it becomes useful.
    #
    # We capture all output from checkm in output files which will also
    # be saved to the workspace.
    #

    my $checkm_dir;
    my $checkm_handle;
    my $checkm_out;
    if ($params->{analyze_quality})
    {
	$checkm_dir = File::Temp->newdir();
	my $checkm_bins = "$checkm_dir/bins";
	$checkm_out = "$checkm_dir/checkm.out";
	my $checkm_tmp = "$checkm_dir/tmp";
	mkdir($checkm_bins) or die "Cannot mkdir $checkm_bins: $!";
	mkdir($checkm_out) or die "Cannot mkdir $checkm_out: $!";
	mkdir($checkm_tmp) or die "Cannot mkdir $checkm_tmp: $!";
	symlink($temp, "$checkm_bins/contigs.fna") or die "Cannot symlink $temp to $checkm_bins/contigs.fna: $!";
	my @cmd = ("checkm", "lineage_wf",
		   "--alignment_file", "$checkm_dir/multi-copy.aln",
		   "--file", "$checkm_out/checkm_out.txt",
		   "--tab_table",
		   "--tmpdir", $checkm_tmp,
		   $checkm_bins,
		   $checkm_out);
	print "Start checkm: @cmd\n";
	$checkm_handle = IPC::Run::start(\@cmd,
					 ">", "$checkm_dir/checkm.stdout",
					 "2>", "$checkm_dir/checkm.stderr");
	$checkm_handle or die "Error starting checkm command @cmd: $!\n";
    }
    

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $core->ctx;
    my $result;
    #
    # Run pipeline and scikit analysis inside eval to trap errors so we can
    # kill the checkm if need be.
    #
    eval {

	$result = $core->run_pipeline($genome, $params->{workflow}, $params->{recipe});

	#
	# Compute scikit-based consistency measure.
	#
	
	if ($params->{analyze_quality})
	{
	    my $tmpdir = File::Temp->newdir(CLEANUP => 1);
	    print "SCIKIT run to $tmpdir\n";
	    
	    my $out = "$tmpdir/scikit.out";
	    mkdir($out) or die "mkdir $out failed: $!";
	    my $g = "$tmpdir/genome.gto";
	    if (open(my $fh, ">", $g))
	    {
		print $fh $json->encode($result);
		close($fh);
	    }
	    else
	    {
		die "Cannot write temp genome $g for scikit analysis: $!";
	    }
	    
	    run_seedtk_cmd("gto_consistency", $g, $out,
			   seedtk . "/data/FunctionPredictors",
			   seedtk . "/data/roles.in.subsystems",
			   seedtk . "/data/roles.to.use");

	    #
	    # Read quality measures.
	    #

	    open(my $qh, "<$out/evaluate.log") || die "Could not open $out/evaluate.log: $!";

	    while (! eof $qh) {
		my $line = <$qh>;
		if ($line =~ /Coarse_Consistency=\s+(\d+(?:\.\d+)?)%/) {
		    $result->{genome_quality_measure}->{coarse_consistency} = 0 + $1;
		} elsif ($line =~ /Fine_Consistency=\s+(\d+(?:\.\d+)?)%/) {
		    $result->{genome_quality_measure}->{fine_consistency} = 0 + $1;
		}
	    }
	    close($qh);

	    #
	    # Internalize the role mapping and evaluation data.
	    #
	    if (open(RMAP, "<", "$out/roles.mapped"))
	    {
		if (open(EVAL, "<", "$out/evaluate.out"))
		{
		    my %role_map;
		    my %role_fids;
		    while (<RMAP>)
		    {
			chomp;
			my($role, $abbr, $fid) = split(/\t/);
			$role_map{$abbr} = $role;
			push(@{$role_fids{$abbr}}, $fid);
		    }
		    close(RMAP);
		    
		    my %role_ok;
		    my %role_ppr;
		    while (<EVAL>)
		    {
			chomp;
			my($abbr, $predicted, $actual) = split(/\t/);
			$predicted = int($predicted);
			$actual = int($actual);
			if ($predicted == $actual)
			{
			    if (1 || $predicted)
			    {
				$role_ok{$abbr} = [$predicted, $actual];
			    }
			}
			else
			{
			    $role_ppr{$abbr} = [$predicted, $actual];
			}
		    }
		    close(EVAL);
		    $result->{genome_quality_measure}->{problematic_roles_report} = {
			roles => \%role_map,
			role_fids => \%role_fids,
			role_ok => \%role_ok,
			role_problematic => \%role_ppr,
		    };
		}
		else
		{
		    close(RMAP);
		    warn "Cannot open $out/evaluate.out: $!";
		}
	    }
	    else
	    {
		warn "Cannot open $out/roles.mapped: $!";
	    }
	}

	#
	# Use the GenomeTypeObject code to compute overall genome metrics.
	#

	my $metrics = GenomeTypeObject::metrics($result);
	%{$result->{genome_quality_measure}->{genome_metrics}} = %$metrics;
    };
    if ($@)
    {
	my $err = $@;
	if ($checkm_handle)
	{
	    warn "Killing checkm due to pipeline error\n";
	    $checkm_handle->kill_kill();
	}
	die $err;
    }

    if ($checkm_handle)
    {
	print STDERR "Awaiting completion of checkm\n";
	my $ok = $checkm_handle->finish();
	if (!$ok)
	{
	    die "Error running checkm: $?\n";
	}

	#
	# Integrate results with genome object.
	#

	if (open(my $fh, "<", "$checkm_out/checkm_out.txt"))
	{
	    my $hdrs = <$fh>;
	    my $data = <$fh>;
	    chomp $hdrs;
	    chomp $data;
	    my @hdrs = split(/\t/, $hdrs);
	    my @data = split(/\t/, $data);
	    for my $i (0..$#hdrs)
	    {
		$result->{genome_quality_measure}->{checkm_data}->{$hdrs[$i]} = $data[$i];
	    }
	    close($fh);
	}
	system("cp", "$checkm_dir/checkm.stdout", "$checkm_dir/checkm.stderr", "$checkm_dir/multi-copy.aln", $checkm_out);
	$ok = IPC::Run::run(["p3-cp", "-m", "stdout=txt", "-m", "stderr=txt", "-R", $checkm_out, "ws:$output_folder"]);
	$ok or warn "p3-cp $checkm_out to ws:$output_folder failed\n";
    }

    {
	local $Bio::KBase::GenomeAnnotation::Service::CallContext = $core->ctx;
	$result = $core->impl->compute_genome_quality_control($result);
    }

    my $gto_path = $core->write_output($genome, $result, {}, undef,
				       $params->{public} ? 1 : 0,
				       $params->{queue_nowait} ? 1 : 0,
				       $params->{skip_indexing} ? 1 : 0);

    #
    # Write the genome quality data as a standalone JSON file to aid in downstream
    # quality summarization.
    #

    $ws->save_data_to_file($json->encode($result->{genome_quality_measure}),
		           {}, "$output_folder/quality.json", "json", 1, 0, $core->token);

    #
    # Determine if we are one of a peer group of jobs that was started
    # on behalf of a parent job. If we are, and if we are the last job running,
    # invoke post-parent-job processing.
    #

    my $parent_output_folder;
    my $run_last;
    
    if (my $parent = $params->{_parent_job})
    {
	my $dsn = "DBI:mysql:database=" . db_name . ";host=" . db_host;
	my $dbh = DBI->connect($dsn, db_user, db_pass, { RaiseError => 1, AutoCommit => 0 });
	
	#
	# Save information about this genome.
	#
	$dbh->do(qq(INSERT INTO GenomeAnnotation_JobDetails (job_id, parent_job, genome_id, genome_name, gto_path)
		    VALUES (?, ?, ?, ?, ?)), undef,
		 $app->task_id, $parent, $genome->{id}, $genome->{scientific_name}, $gto_path);
	$dbh->commit();

	my $sth = $dbh->prepare(qq(SELECT children_created, children_completed, parent_app, app_spec, app_params
				   FROM JobGroup
				   WHERE parent_job = ?
				   FOR UPDATE));
	my $res = $sth->execute($parent);
	my $last_job = 0;
	my($created, $completed, $app, $spec, $params);
	if ($res != 1)
	{
	    warn "Missing parent job $parent in database\n";
	}
	else
	{
	    ($created, $completed, $app, $spec, $params) = $sth->fetchrow_array();
	    print "Created=$created completed=$completed\n";

	    eval {
		my $params_dat = decode_json($params);
		$parent_output_folder = $params_dat->{output_path} . "/." . $params_dat->{output_file};
		print STDERR "Found parent output folder $parent_output_folder\n";
	    };
	    if ($@)
	    {
		warn "Error parsing parent job params data : $@\n$params\n";
	    }

	    if ($completed == $created - 1)
	    {
		print "We are the last one out!\n";
		$last_job = 1;
	    }
	    elsif ($completed < $created - 1)
	    {
		print "Not so many gone\n";
	    }
	    else
	    {
		warn "completed=$completed created=$created - should not happen here\n";
	    }
	    my $n = $dbh->do(qq(UPDATE JobGroup
				SET children_completed = children_completed + 1
				WHERE parent_job = ? AND children_completed = ?), undef,
			     $parent, $completed);
	    if ($n == 0)
	    {
		print "Failed on update - not us!\n";
	    }
	    else
	    {
		print "Completed with n=$n\n";
	    }
	}

	$dbh->commit();
	if ($last_job)
	{
	    #
	    # We defer this until we are outside this block so we can ensure
	    # the genome report is written first.
	    #
	    $run_last = sub { $core->run_last_job_processing($parent, $app, $spec, $params); };
	}
    }

    #
    # Write the details report for this genome.
    #

    my $bins;
    if ($parent_output_folder)
    {
	eval {
	    print "Trying to load bins from $parent_output_folder/bins.json";
	    $bins = $ws->download_json("$parent_output_folder/bins.json", $core->token);
	};
	if ($@)
	{
	    warn "Could not load bins from $parent_output_folder/bins.json: $@\n";
	}
    }

    my $mpath = Module::Metadata->find_module_by_name("BinningReports");
    $mpath =~ s/\.pm$//;
    
    my $details_tt = "$mpath/details.tt";
    -f $details_tt or die "Details not found at $details_tt\n";
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

    my $html = BinningReports::Detail($params, $bins, $details_tt, $result, \%role_map);
    $ws->save_data_to_file($html, {}, "$output_folder/GenomeReport.html", "html", 1, 0, $core->token);
    
    #
    # Do last-job processing if needed.
    #
    &$run_last if $run_last;

    $core->ctx->stderr(undef);
}

sub run_seedtk_cmd
{
    my(@cmd) = @_;
    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";
    my $ok = IPC::Run::run(@cmd);
    $ok or die "Failure $? running seedtk cmd: " . Dumper(\@cmd);
}
