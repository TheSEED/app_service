#
# The Sleep application.
#

use Bio::KBase::AppService::AppScript;
use strict;

my $script = Bio::KBase::AppService::AppScript->new(\&sleep);

$script->run(\@ARGV);

sub sleep
{
    my($app, $app_def, $raw_params, $params) = @_;
    
    my $time = $params->{sleep_time};
    print "Sleeping for $time seconds\n";
    sleep($time);
    my $now = `date`;
    chomp $now;
    print "Done sleeping. It is now $now\n";
}
