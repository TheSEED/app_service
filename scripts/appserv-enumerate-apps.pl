use Bio::KBase::AppService::Client;
use Getopt::Long::Descriptive;
use strict;
use Data::Dumper;

my($opt, $usage) = describe_options("%c %o",
				    ["url|u=s", "Service URL"],
				    ["help|h", "Show this help message"]);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if (@ARGV != 0);

my $client = Bio::KBase::AppService::Client->new($opt->url);

my $apps = $client->enumerate_apps();

my $mlab = 0;
my $mid = 0;
for my $app (@$apps)
{
    my $l = length($app->{id});
    $mid = $l if $l > $mid;
    $l = length($app->{label});
    $mlab = $l if $l > $mlab;
}

printf "%-${mid}s   %-${mlab}s   Description\n", "ID", "Label";
printf "%-${mid}s   %-${mlab}s   -----------\n", "--", "-----";
for my $app (@$apps)
{
    printf "%-${mid}s   %-${mlab}s   $app->{description}\n", $app->{id}, $app->{label};
}

