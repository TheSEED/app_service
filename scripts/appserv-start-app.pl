use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;
use JSON::XS;
use File::Slurp;

my($opt, $usage) = describe_options("%c %o app-id params-data workspace",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if (@ARGV != 3);

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $app_id = shift;
my $params_data = shift;
my $workspace = shift;

my $params = decode_json(scalar read_file($params_data));

my $task = $client->start_app($app_id, $params, $workspace);

print Dumper($task);
