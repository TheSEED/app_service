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
					 app_directory app_service_url redis_host redis_port redis_db);
use P3AuthToken;
use IO::File;
use File::Slurp;
use File::Temp;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o token app-id task-params start-params output-task",
				    ["user-error-file=s" => "File to write user-level error", { default => "/dev/null"}],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 5;

my $json = JSON::XS->new->pretty(1);

my $token = shift;
my $app_id = shift;
my $task_params_file = shift;
my $start_params_file = shift;
my $output_task_file = shift;

my $error_fh;
open($error_fh, ">>", $opt->user_error_file);
$error_fh->autoflush(1);

my $db = Bio::KBase::AppService::SchedulerDB->new();

my $redis = Redis::hiredis->new(host => redis_host,
				(redis_port ? (port => redis_port) : ()));
$redis->command("select", redis_db);


my $token_obj = P3AuthToken->new(token => $token);

my $specs = Bio::KBase::AppService::AppSpecs->new(app_directory);

my $app = $db->find_app($app_id, $specs);

my $appserv_info_url = app_service_url . "/task_info";

my $app_tmp = File::Temp->new();
print $app_tmp $app->{spec};
close($app_tmp);

#
# Run preflight.
#

my $preflight_tmp = File::Temp->new();
close($preflight_tmp);

$ENV{P3_AUTH_TOKEN} = $ENV{KB_AUTH_TOKEN} = $token;

my @preflight = ($app->{script},
		 "--user-error-file", $opt->user_error_file,
		 "--preflight", "$preflight_tmp",
		 $appserv_info_url, "$app_tmp", $task_params_file);
my $rc = system(@preflight);
if ($rc != 0)
{

    die "Preflight @preflight failed with rc=$rc\n";
}

#
# Make sure we can parse preflight & parameter files as json.
#

my $preflight = read_and_parse("$preflight_tmp", {});
my $task_params = read_and_parse($task_params_file);
my $start_params = read_and_parse($start_params_file);

my $task = $db->create_task($token_obj, $app_id, $appserv_info_url,
				$task_params, $start_params, $preflight);
write_file($output_task_file, $json->encode($task));
$redis->command("publish", "task_submission", $task->{id});

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
