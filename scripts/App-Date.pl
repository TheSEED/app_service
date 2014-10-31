#
# The Date application.
#

use strict;
use JSON::XS;
use File::Slurp;
use IO::File;
use Capture::Tiny 'capture';

use Data::Dumper;

@ARGV == 2 or @ARGV == 4 or die "Usage: $0 app-definition.json param-values.json [stdout-file stderr-file]\n";

my $json = JSON::XS->new->pretty(1);

my $app_def_file = shift;
my $params_file = shift;

my $stdout_file = shift;
my $stderr_file = shift;

if ($stdout_file)
{
    my $stdout_fh = IO::File->new($stdout_file, "w+");
    my $stderr_fh = IO::File->new($stderr_file, "w+");

    capture(sub { run($app_def_file, $params_file) } , stdout => $stdout_fh, stderr => $stderr_fh);
}
else
{
    run($app_def_file, $params_file);
}

sub run
{
    my($app_def_file, $params_file) = @_;

    my $app_def = $json->decode(scalar read_file($app_def_file));
    my $params =  $json->decode(scalar read_file($params_file));


    print STDERR "Initializing app\n";
    print STDERR Dumper($app_def, $params);
    
    my $now = `date`;
    chomp $now;
    
    print "It is now $now\n";
}
