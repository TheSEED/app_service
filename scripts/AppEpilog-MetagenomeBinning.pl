
#
# Metagenomic binning epilog script.
#
# This is invoked by the last genome annotation run on a bin from the
# metagenome.
#
# We are running with the task ID of the last genome annotation. We use this
# to look up in the GenomeAnnotation_JobDetails table to find the job ID
# of the parent, and then enumerate the child jobs.
#
# For each, save the annotated gto into a gto directory named as genome-id.gto.
#
# Create a package directory package-dir
# Then run the SEEDtk script "package_gto gto-dir all package-dir
# Now we an use the SEEDtk package/bin scripts to do the analysis required:
#   bins -d package-dir checkM <genome-id>
#   bins -d package-dir eval_scikit <genome_id>
#   bins -d package-dir quality_summary <genome_id>
#
#
# The epilog script uses the AppScript infrastructure to enable logging to
# the PATRIC monitoring service.
#

use Bio::KBase::AppService::BinningReport;
use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::MetagenomeBinning;
use FileHandle;
use File::Slurp;
use strict;
use Data::Dumper;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name seedtk);
use DBI;
use Cwd 'abs_path';
use JSON::XS;
use IPC::Run;
use Proc::ParallelLoop;

my $script = Bio::KBase::AppService::AppScript->new(\&process);
$script->donot_create_result_folder(1);

my $rc = $script->run(\@ARGV);

exit $rc;

sub process
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $task = $app->task_id;

    #
    # Connect to database to determine parent's task id, then enumerate
    # genomes to be processed.
    #

    my $dsn = "DBI:mysql:database=" . db_name . ";host=" . db_host;
    my $dbh = DBI->connect($dsn, db_user, db_pass, { RaiseError => 1, AutoCommit => 0 });

    my $ginfo = $dbh->selectall_arrayref(qq(SELECT parent_job
					 FROM GenomeAnnotation_JobDetails
					 WHERE job_id = ?),
				      undef, $task);
    if (!@$ginfo)
    {
	die "Could not find parent job for task='$task'\n";
    }
    my $parent = $ginfo->[0]->[0];
    print "Parent task=$parent\n";
    
    my $genome_list = $dbh->selectall_arrayref(qq(SELECT job_id, genome_id, genome_name, gto_path
						  FROM GenomeAnnotation_JobDetails
						  WHERE parent_job = ?),
					       undef, $parent);

    my $qual_dir = abs_path("qual_dir");
    mkdir($qual_dir);

    my $fh_pairs = [];
    my @genomes;
    for my $ent (@$genome_list)
    {
	my($job, $genome_id, $genome_name, $gto_path) = @$ent;
	my $local_path = "$qual_dir/$genome_id.qual.json";
	my $local_fh = FileHandle->new($local_path, "w");
 	push(@$fh_pairs, [$gto_path, $local_fh]);
	push(@genomes, $genome_id);
    }
    $app->workspace->copy_files_to_handles(1, $app->token(), $fh_pairs);
    close($_->[1]) foreach @$fh_pairs;


    # since we are an epilog we don't create output folder which means
    # that value not currently set. Change that.
    #
    # my $output_folder = $app->result_folder();
    #
    # until then copy this code.
    #
    my $base_folder = $params->{output_path};
    my $output_folder = $base_folder . "/." . $params->{output_file};

    #
    # Write the genome group
    #
    my $group_path;
    if (my $group = $params->{genome_group})
    {
	my $home;
	if ($app->token->token =~ /(^|\|)un=([^|]+)/)
	{
	    my $un = $2;
	    $home = "/$un/home";
	}

	if ($home)
	{
	    $group_path = "$home/Genome Groups/$group";
	    
	    my $group_data = { id_list => { genome_id => \@genomes } };
	    my $group_txt = encode_json($group_data);
	    
	    my $res = $app->workspace->create({
		objects => [[$group_path, "genome_group", {}, $group_txt]],
		permission => "w",
		overwrite => 1,
	    });
	    print Dumper(group_create => $res);
	}
	else
	{
	    warn "Cannot find home path '$home'\n";
	}
    }
    #
    # Generate the binning report. We need to load the various reports into memory to do this.
    #

    #
    # Load bins report from original binning run.
    #
    eval {
	my $bins_report = load_workspace_json($app->workspace, "$output_folder/bins.json");
	my $qual_report = decode_json(scalar read_file("quality.json"));

	my($params_txt) = $dbh->selectrow_array(qq(SELECT app_params
						   FROM JobGroup
						   WHERE parent_job = ?), undef, $parent);
	my $parent_params = decode_json($params_txt);

	#
	# Hold off until we finish new reporting.
	#
	# open(my $out, ">", "report.html") or die "Cannot write report.html: $!";
	# Bio::KBase::AppService::BinningReport::write_report($parent, $parent_params,
	# 						    $qual_report, $ppr_report, $bins_report,
	# 						    $group_path,
	# 						    $out);
	# close($out);
	# $app->workspace->save_file_to_file("report.html", {},
	# 				   "$output_folder/report.html", 'html', 1, 1, $app->token);
    };
    if ($@)
    {
	warn "Error creating final report: $@";
    }

}

sub run_seedtk_cmd
{
    my(@cmd) = @_;
    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";
    my $ok = IPC::Run::run(@cmd);
    $ok or die "Failure $? running seedtk cmd: " . Dumper(\@cmd);
}

sub load_workspace_json
{
    my($ws, $path) = @_;

    my $str;
    open(my $fh, ">", \$str) or die "Cannot open string reference filehandle: $!";

    eval {
	$ws->copy_files_to_handles(1, $ws->{token}, [[$path, $fh]]);
    };
    if ($@)
    {
	my($err) = $@ =~ /_ERROR_(.*)_ERROR_/;
	$err //= $@;
	die "load_workspace_json: failed to load $path: $err\n";
    }
    close($fh);

    my $doc = eval { decode_json($str) };

    if ($@)
    {
	die "Error parsing json: $@";
    }
    return $doc;
}
