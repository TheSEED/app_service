#
# The Genome Annotation application.
# temp copy that rips out the checkm/eval code
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::GenomeAnnotationCore;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name seedtk);
use Bio::KBase::AppService::FastaParser 'parse_fasta';
use Bio::KBase::AppService::LongestCommonSubstring qw(BuildString BuildTree LongestCommonSubstring);
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

my $script = Bio::KBase::AppService::AppScript->new(\&process_genome, \&preflight);

my $rc = $script->run(\@ARGV);

exit $rc;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    #
    # Ensure the contigs are valid, and look up their size.
    #

    my $ctg = $params->{contigs};
    $ctg or die "Contigs must be specified\n";

    my $res = $app->workspace->stat($ctg);
    $res->size > 0 or die "Contigs not found\n";

    #
    # Size estimate based on conservative 500 bytes/second aggregate
    # compute rate for contig size, with a minimum allocated
    # time of 60 minutes (to account for non-annotation portions).
    #
    my $time = $res->size / 500;
    $time = 3600 if $time < 3600;

    #
    # Request 8 cpus for some of the fatter bits of the compute.
    #
    return {
	cpu => 8,
	memory => "8G",
	runtime => int($time),
	storage => 10 * $res->size,
    };
}

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
    
    close($temp);
    my $contig_data_fh = open_contigs("$temp");


    #
    # Use the state-machine based parser ported from RAST.
    #
    # We do an initial read of the first 64 ids of the file. If any of these are too long,
    # we compute the longest common substring to use to replace clip out and replace with
    # "contigs_" to shorten the ids. We keep a mapping from new name to original name.
    #
    # This should hit the common cases where we have IDs like
    # SA-B-8-4-Neg_un-mapped_reads_[SA-B-8-4-Neg_S4_L001_R1_001]_(paired)_contig_22
    # or
    # Ahmed6_GGACTCC_L005_R1_001_(paired)_trimmed_(paired)_merged_contig_1
    #

    my $n = 0;
    my @ids;
    my $too_long = 0;
    my $max_id_len = 60;
    parse_fasta($contig_data_fh, undef, sub {
	my($id, $seq) = @_;
	push(@ids, $id);
	$too_long++ if length($id) > $max_id_len;
	$n++;
	return ($n < 64);
    });
    close($contig_data_fh);

    if ($n == 0)
    {
	die "No contigs loaded from $temp $input_path\n";
    }

    my %name_map;
    my %name_rev_map;
    my $lcs;
    my $qlcs;
    if ($too_long)
    {
	if ($n == 1)
	{
	    $name_map{'contig'} = $ids[0];
	    $name_rev_map{$ids[0]} = 'contig';
	}
	else
	{
	    BuildString(@ids);
	    my $tree = BuildTree();
	    $lcs = LongestCommonSubstring($tree);
	    $qlcs = quotemeta($lcs);
	    print STDERR "Shortening contig names using longest substring '$lcs'\n";
	}
    }

    #
    # Reopen the file and load data, remapping names if necessary.
    #

    $contig_data_fh = open_contigs("$temp");

    my $n = 0;
    my @contigs;
    parse_fasta($contig_data_fh, undef, sub {
	my($id, $seq) = @_;

	my $orig_id = $id;
	my @orig;
	if ($name_rev_map{$id})
	{
	    $id = $name_rev_map{$id};
	    @orig = (original_id => $orig_id);
	}
	elsif ($lcs)
	{
	    $id =~ s/$qlcs/contig_/;
	    @orig = (original_id => $orig_id);
	}
	if (length($id) > $max_id_len)
	{
	    die "Contig id $orig_id too long even after shortening to $id via longest substring $lcs\n";
	}

	push(@contigs, { id => $id, dna => $seq, @orig });
	$n++;
	return 1;
    });
    close($contig_data_fh);
    $core->impl->add_contigs($genome, \@contigs);

    local $Bio::KBase::GenomeAnnotation::Service::CallContext = $core->ctx;
    my $result;
    #
    # Run pipeline and scikit analysis inside eval to trap errors so we can
    # kill the checkm if need be.
    #
    my $override;
    if (my $ref = $params->{reference_genome_id})
    {
	$override->{evaluate_genome} =  {
	    evaluate_genome_parameters => { reference_genome_id => $ref },
	};
    }
    if (my $ref = $params->{reference_virus_name})
    {
	$override->{call_features_vigor4} =  {
	    vigor4_parameters => { reference_name => $ref },
	};
    }
    
    $result = $core->run_pipeline($genome, $params->{workflow}, $params->{recipe}, $override);

    my($gto_path, $index_queue_id) = $core->write_output($genome, $result, {}, undef,
							 $params->{public} ? 1 : 0,
							 $params->{queue_nowait} ? 1 : 0,
							 $params->{skip_indexing} ? 1 : 0);

    #
    # Write the genome quality data as a standalone JSON file to aid in downstream
    # quality summarization.
    #

    if (ref($result->{quality}))
    {
	$ws->save_data_to_file($json->encode($result->{quality}),
		           {}, "$output_folder/quality.json", "json", 1, 1, $core->token);
    }

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
    # Do last-job processing if needed.
    #
    &$run_last if $run_last;

    $core->ctx->stderr(undef);

    return {
	gto_path => $gto_path,
	index_queue_id => $index_queue_id,
    };
}

sub open_contigs
{
    my($file) = @_;
    my $contig_data_fh;
    open($contig_data_fh, "<", $file) or die "Cannot open contig file $file: $!";

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
	open($contig_data_fh, "-|", "gzip", "-d", "-c", $file) or die "Cannot open gzip from $file: $!";
    }
    else
    {
	$contig_data_fh->seek(0, 0);
    }

    return $contig_data_fh;
}

sub run_seedtk_cmd
{
    my(@cmd) = @_;
    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";
    my $ok = IPC::Run::run(@cmd);
    $ok or die "Failure $? running seedtk cmd: " . Dumper(\@cmd);
}
