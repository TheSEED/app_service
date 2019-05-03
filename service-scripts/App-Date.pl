#
# The Date application.
#

use Bio::KBase::AppService::AppScript;
use Bio::P3::Workspace::WorkspaceClient;
use Bio::P3::Workspace::WorkspaceClientExt;
use strict;
use Data::Dumper;
use gjoseqlib;
use File::Basename;
use LWP::UserAgent;
use JSON::XS;

my $script = Bio::KBase::AppService::AppScript->new(\&date);

$script->run(\@ARGV);

sub date
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Date: ", Dumper($app_def, $raw_params, $params);

    my $folder = $app->result_folder();

    my $date = `date`;
    $app->workspace->save_data_to_file($date, {}, "$folder/now", undef, 1);

}
