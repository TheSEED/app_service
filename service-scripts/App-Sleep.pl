#
# The Sleep application.
#

use Bio::KBase::AppService::AppScript;
use strict;

my $script = Bio::KBase::AppService::AppScript->new(\&sleep, \&preflight);
$script->donot_create_result_folder(1);

$script->run(\@ARGV);

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $pf = {
	cpu => 1,
	memory => "2G",
	runtime => 2 * ($params->{sleep_time} // 60),
	storage => 0,
	is_control_task => 0,
    };
    return $pf;
}

sub sleep
{
    my($app, $app_def, $raw_params, $params) = @_;

    $SIG{INT} = $SIG{TERM} = $SIG{HUP} = \&sighandler;

    my $time = $params->{sleep_time};
    print "Sleeping for $time seconds\n";
    sleep($time);
    my $now = `date`;
    chomp $now;
    print "Done sleeping. It is now $now\n";
}

sub sighandler
{
    my($sig) = @_;
    print STDERR "Caught signal $sig\n";
#    exit 1;
}
