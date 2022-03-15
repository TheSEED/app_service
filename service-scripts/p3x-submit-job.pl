=head1 NAME
    
    p3x-submit-job -- submit a job
    
=head1 SYNOPSIS

    p3x-submit-job token app-id task-params start-params
    
=head1 DESCRIPTION

Start a job.

The application preflight is invoked; if it is successful, the job is submitted.

If either fails an error message is written to stderr and a nonzero exit code is returned.

=cut

use strict;
use Data::Dumper;

use JSON::XS;
use Try::Tiny;
use DBI;
use Redis::hiredis;
use Bio::KBase::AppService::AppSpecs;
use Bio::KBase::AppService::SchedulerDB;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name
					 app_directory app_service_url redis_host redis_port redis_db
					 sched_default_cluster);
use P3AuthToken;
use IPC::Run;
use IO::File;
use File::Basename;
use File::Slurp;
use File::Copy;
use File::Temp;
use Getopt::Long::Descriptive;
use Cwd qw(getcwd abs_path);

my($opt, $usage) = describe_options("%c %o token app-id task-params start-params output-task",
				    ["user-error-file=s" => "File to write user-level error", { default => "/dev/null"}],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 5;

my $json = JSON::XS->new->pretty(1)->relaxed;

my $token = shift;
my $app_id = shift;
my $task_params_file = shift;
my $start_params_file = shift;
my $output_task_file = shift;

-f $task_params_file or die "Task parameters file $task_params_file does not exist\n";
-f $start_params_file or die "Start parameters file $start_params_file does not exist\n";

my $task_params = read_and_parse($task_params_file);
my $start_params = read_and_parse($start_params_file);

open(OUT_TASK, ">", $output_task_file) or die "Cannot write $output_task_file: $!";
$start_params_file = abs_path($start_params_file);
$task_params_file = abs_path($task_params_file);

my $error_fh;
open($error_fh, ">>", $opt->user_error_file);
$error_fh->autoflush(1);

my $db = Bio::KBase::AppService::SchedulerDB->new();

my $redis;
if (redis_host)
{
    $redis = Redis::hiredis->new(host => redis_host,
				 (redis_port ? (port => redis_port) : ()));
    $redis->command("select", redis_db);
}


my $token_obj = P3AuthToken->new(token => $token);

my $appserv_info_url = app_service_url . "/task_info";

my $preflight;
my $app_spec;

#
# Determine if the start parameters defines a preflight override.
# We need to validate that the job submitter is allowed to do so; if they are
# not we ignore the preflight request.
#
# If we don't run preflight we also do not get verification of app spec.
# This is OK; we will pull it from the database.
#

my $task_params = read_and_parse($task_params_file);
my $start_params = read_and_parse($start_params_file);

if ($start_params->{disable_preflight})
{
    my $user = $token_obj->user_id;

    my $res = $db->dbh->selectrow_arrayref(qq(select is_staff from ServiceUser where id = ?), undef, $user);
    if (!$res || @$res == 0 || !$res->[0])
    {
	($preflight, $app_spec) = run_preflight();
    }
    else
    {
	$preflight = $start_params->{preflight_data};
	my $res = $db->dbh->selectrow_arrayref(qq(SELECT spec FROM Application WHERE id = ?), undef, $app_id);
	$app_spec = decode_json($res->[0]);
    }
}
else
{
    ($preflight, $app_spec) = run_preflight();
}

#
# Force a runtime limit of three days if no limit provided.
#
if ($preflight->{runtime} == 0)
{
    $preflight->{runtime} = 3 * 86400;
}

my $task = $db->create_task($token_obj, $app_id, $appserv_info_url,
			    $task_params, $start_params, $preflight, $app_spec);
print OUT_TASK $json->encode($task);
close(OUT_TASK);


$redis->command("publish", "task_submission", $task->{id}) if $redis;

sub run_preflight
{
    #
    # We set up a temp space to run the container.
    #
    
    my $tmpdir = File::Temp->newdir();
    
    #
    # Copy params file into temp space
    my $task_params_tmp = basename($task_params_file);
    copy($task_params_file, "$tmpdir/$task_params_tmp");
    
    my $start_params_tmp = basename($start_params_file);
    copy($start_params_file, "$tmpdir/$start_params_tmp");
    
    
    my $prev_dir = getcwd;
    chdir($tmpdir);
    
    #
    # Run preflight.
    #
    
    #my $preflight_tmp = File::Temp->new();
    #close($preflight_tmp);
    
    my $preflight_tmp = "preflight.json";
    
    $ENV{P3_AUTH_TOKEN} = $ENV{KB_AUTH_TOKEN} = $token;
    
    #
    # Determine if our default cluster has a default container defined.
    # If so use that for our preflight.
    #
    
    my $container_path;
    my($repo_url, $container_id, $cache_dir, $container_file) = $db->cluster_default_container(sched_default_cluster);
    if ($repo_url)
    {
	#
	# Check for app override of container
	#
	my $task_container = $db->determine_container_id_override($task_params, $start_params);
	
	if (!$task_container)
	{
	    # Check for container defined for base url
	    if (my $base_url = $start_params->{base_url})
	    {
		my $site_default = $db->schema->resultset("SiteDefaultContainer")->find($base_url);
		if ($site_default)
		{
		    $task_container = $site_default->default_container_id;
		    print STDERR "found container $task_container for $base_url\n";
		}
	    }
	}
	
	if ($task_container)
	{
	    print STDERR "Task specifies container; validating\n";
	    $container_file = $db->find_container($task_container);
	    if (!$container_file)
	    {
		chdir($prev_dir);
		die "Task-specfied container $task_container not valid\n";
	    }
	    $container_id = $task_container;
	}
	print STDERR "Pulling container $container_file if necessary\n";
	my $rc = system("p3x-download-compute-image",
			$repo_url, $tmpdir, $container_file, $cache_dir);
	if ($rc != 0)
	{
	    warn "Failed to pull compute image\n";
	}
	$container_path = "$cache_dir/$container_file";
    }
    
    my $app_tmp = "app_spec.json";
    
    my $pf_error = "preflight.err";
    
    my $preflight_script = "p3x-run-preflight";
    my @preflight_opts = ("--user-error-file", $pf_error,
			  $app_id, $appserv_info_url, $task_params_tmp, $preflight_tmp);
    
    #
    # If not running from a container, we use the app specs that we get from our
    # current environment.
    #
    # If running from a container, we ask the preflight app to get them
    # from that environment, and save them to a file that we can read
    # and then pass to the database at task creation time.
    #
    
    if ($container_path)
    {
	my @cmd = ($preflight_script,
		   "--app-data-from-deployment", $app_tmp,
		   @preflight_opts);
	
	my @singularity_opts;
	
	if (-d "/vol/blastdb/bvbrc-service")
	{
	    push(@singularity_opts, "-B", "/vol/blastdb/bvbrc-service");
	}
	
	print STDERR "Execute preflight in $container_path: @cmd\n";
	my $err;
	my $ok = IPC::Run::run(["singularity", "exec",
				@singularity_opts,
				$container_path, @cmd],
			       "2>", \$err);
	if (!$ok)
	{
	    my $ec = $?;
	    if ($err =~ /p3x-run-preflight.*executable\s+file\s+not\s+found/)
	    {
		#
		# We're submitting to a container without p3x-run-preflight. We'll
		# need to look up the script in this deployment and run that in the container.
		#
		
		my $specs = Bio::KBase::AppService::AppSpecs->new(app_directory);
		my $app = $db->find_app($app_id, $specs);
		write_file($app_tmp, $app->{spec});
		
		my @preflight = ($app->{script},
				 "--user-error-file", $pf_error,
				 "--preflight", $preflight_tmp,
				 $appserv_info_url, $app_tmp, $task_params_tmp);
		print STDERR "Falling back to old-style container preflight @preflight\n";
		my $rc = system(@preflight);
		if ($rc != 0)
		{
		    copy("$tmpdir/$pf_error", $error_fh);
		    chdir($prev_dir);
		    die "Singularity Preflight in container $container_path @preflight failed with rc=$rc\n";
		}
	    }
	    else
	    {
		system("ls -al $tmpdir");
		copy("$tmpdir/$pf_error", $error_fh);
		chdir($prev_dir);
		die "Singularity Preflight in container $container_path @cmd failed with $ec\n";
	    }
	}
	
	$app_tmp = abs_path($app_tmp);
	chdir($prev_dir);
    }
    else
    {
	my $specs = Bio::KBase::AppService::AppSpecs->new(app_directory);
	my $app = $db->find_app($app_id, $specs);
	write_file($app_tmp, $app->{spec});
	
	my @cmd = ($preflight_script,
		   "--app-data-file", $app_tmp,
		   @preflight_opts);
	
	my $rc = system(@cmd);
	$app_tmp = abs_path($app_tmp);
	chdir($prev_dir);
	if ($rc != 0)
	{
	    copy($pf_error, $error_fh);
	    die "Preflight @cmd failed with rc=$rc\n";
	}
    }

    #
    # Make sure we can parse preflight & parameter files as json.
    #
    
    my $preflight = read_and_parse("$tmpdir/$preflight_tmp", {});
    my $app_spec = read_and_parse($app_tmp);
    return ($preflight, $app_spec);
}


sub read_and_parse
{
    my($file, $fallback) = @_;
    my $obj;
    try {
	my $text = read_file($file);
	$obj = $json->decode($text);
    }
    catch {
	if ($fallback)
	{
	    warn "Could not read and parse $file: $_";
	    $obj = $fallback;
	}
	else
	{
	    die "Could not read and parse $file: $_";
	}
    };
    return $obj;
};
