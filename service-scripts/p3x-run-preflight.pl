=head1 NAME
    
    p3x-run-preflight - run job preflight
    
=head1 SYNOPSIS

    p3x-run-preflight app-id task-params
    
=head1 DESCRIPTION

Run job preflight.

=cut

use strict;
use Data::Dumper;

use JSON::XS;
use Try::Tiny;
use DBI;
use Redis::hiredis;
use Bio::KBase::AppService::AppSpecs;

use P3AuthToken;
use IO::File;
use File::Basename;
use File::Slurp;
use File::Copy;
use File::Temp;
use Getopt::Long::Descriptive;
use Cwd qw(getcwd abs_path);

my($opt, $usage) = describe_options("%c %o app-id info-url task-params preflight-output",
				    ["app-data-from-deployment=s" => "Use deployment to load app spec data and write to this file"],
				    ["app-data-file=s" => "Use this app spec data"],
				    ["user-error-file=s" => "File to write user-level error"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 4;

my $json = JSON::XS->new->pretty(1);

my $app_id = shift;
my $info_url = shift;
my $task_params_file = shift;
my $preflight_output = shift;

-f $task_params_file or die "Task parameters file $task_params_file does not exist\n";

my $task_params = read_and_parse($task_params_file);

#
# If requested, find the app spec file from the local environment.
#

my $app_spec_file;
my $app_spec;

if ($app_spec_file = $opt->app_data_from_deployment)
{
    if ($opt->app_data_file)
    {
	die "$0: Only one of --app-data-from-deployment and --app-data-file may be specified\n";
    }

    my $specs = Bio::KBase::AppService::AppSpecs->new();
    ($app_spec, my $file) = $specs->find($app_id);
    
    if (!$app_spec)
    {
	die "Cannot find spec file for $app_id in " . join(" ", @{$specs->spec_dirs}) . "\n";
    }
    copy($file, $app_spec_file);
}
elsif ($app_spec_file = $opt->app_data_file)
{
    $app_spec = read_and_parse($app_spec_file);
}
else
{
    die "$0: One of --app-data-from-deployment and --app-data-file must be specified\n";
} 
    
my @cmd = ($app_spec->{script},
	   "--preflight", $preflight_output,
	   ($opt->user_error_file ? ("--user-error-file", $opt->user_error_file) : ()),
	   $info_url, $app_spec_file, $task_params_file);

my $rc = system(@cmd);

if ($rc != 0)
{
    die "Preflight failed with $rc: @cmd\n";
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
