use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

my($opt, $usage) = describe_options("%c %o app-id params-data [workspace]",
				    ["output-path|d=s", "Change the output path"],
				    ["output-file|f=s", "Change the output file"],
				    ["id-file=s", "Save the generated task id to this file"],
				    ["container-id|c=s", "Use the specified container"],
				    ["data-container-id|D=s", "Use the specified data container"],
				    ["base-url|b=s", "Submit with the chosen base URL"],
				    ["user-metadata=s", "Tag the job with the given metadata"],
				    ["user-metadata-file=s", "Tag the job with the given metadata from this file"],
				    ["verbose|v", "Show verbose output"],
				    ["reservation=s", "Slurm reservation", { hidden => 1 }],
				    ["constraint=s", "Slurm constraint", { hidden => 1 }],
				    ["url|u=s", "Service URL"],
				    ["preflight=s\@", "Specify a preflight parameter using e.g. --preflight cpu=2. Disables automated preflight, requires administrator access", { hidden => 1, default => []}],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if @ARGV != 3 && @ARGV != 2;

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $app_id = shift;
my $params_data = shift;
my $workspace = shift;

my $params = decode_json(scalar read_file($params_data));

my %preflight_params;
if (@{$opt->preflight})
{
    my $phash = {};
    for my $p (@{$opt->preflight})
    {
	my($k, $v) = split(/=/, $p, 2);
	if (!defined($k) || !defined($v))
	{
	    die "Invalid preflight option $p\n";
	}
	$phash->{$k} = $v;
    }
    %preflight_params = (disable_preflight => 1, preflight_data => $phash );
}

my $user_metadata = $opt->user_metadata;
if ($opt->user_metadata_file)
{
    $user_metadata = read_file($opt->user_metadata);
}


my $start_params = {
    defined($workspace) ? (workspace => $workspace) : (),
    $opt->container_id ? (container_id => $opt->container_id) : (),
    $opt->data_container_id ? (data_container_id => $opt->data_container_id) : (),
    $opt->base_url ? (base_url => $opt->base_url) : (),
    $opt->reservation ? (reservation => $opt->reservation) : (),
    $opt->constraint ? (constraint => $opt->constraint) : (),
    defined($user_metadata) ? (user_metadata => $user_metadata) : (),
    %preflight_params,
};
    
if ($params->{output_path} && $opt->output_path)
{
    print "Change output path from $params->{output_path} to " . $opt->output_path . "\n";
    $params->{output_path} = $opt->output_path;
}

if ($params->{output_file} && $opt->output_file)
{
    print "Change output file from $params->{output_file} to " . $opt->output_file . "\n";
    $params->{output_file} = $opt->output_file;
}

my $task = $client->start_app2($app_id, $params, $start_params);

if ($opt->verbose)
{
    print Dumper($task);
}
print "Started task $task->{id}\n";
if ($opt->id_file)
{
    open(F, ">", $opt->id_file) or die "Cannot write id file " . $opt->id_file . ": $!\n";
    print F "$task->{id}\n";
    close(F);
}
