use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

my($opt, $usage) = describe_options("%c %o app-id params-data [workspace]",
				    ["output-path|d=s", "Change the output path"],
				    ["output-file|f=s", "Change the output file"],
				    ["container-id|c=s", "Use the specified container"],
				    ["base-url|b=s", "Submit with the chosen base URL"],
				    ["user-metadata=s", "Tag the job with the given metadata"],
				    ["user-metadata-file=s", "Tag the job with the given metadata from this file"],
				    ["verbose|v", "Show verbose output"],
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if @ARGV != 3 && @ARGV != 2;

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $app_id = shift;
my $params_data = shift;
my $workspace = shift;

my $params = decode_json(scalar read_file($params_data));

my $user_metadata = $opt->user_metadata;
if ($opt->user_metadata_file)
{
    $user_metadata = read_file($opt->user_metadata);
}


my $start_params = {
    defined($workspace) ? (workspace => $workspace) : (),
    $opt->container_id ? (container_id => $opt->container_id) : (),
    $opt->base_url ? (base_url => $opt->base_url) : (),
    defined($user_metadata) ? (user_metadata => $user_metadata) : (),
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
