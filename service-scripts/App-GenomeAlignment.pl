#
# The Whole Genome Alignment application (Mauve).
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::AppConfig;

use strict;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run qw(run);
use Cwd;
use Clone;

my $script = Bio::KBase::AppService::AppScript->new(\&process_alignment, \&preflight_cb);

my $rc = $script->run(\@ARGV);

exit $rc;

#
# Run preflight to estimate size and duration.
#
sub preflight_cb
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $time = 60 * 60 * 2;

    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => $time,
	storage => 0,
    };
    return $pf;
}

sub process_alignment
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc Mauve", Dumper($app_def, $raw_params, $params);

    my $token = $app->token();
    my $output_folder = $app->result_folder();

    #
    # Create an output directory under the current dir. App service is meant to invoke
    # the app script in a working directory; we create a folder here to encapsulate
    # the job output.
    #
    my $cwd = getcwd();
    my $work_dir = "$cwd/work";
    -d $work_dir or mkdir $work_dir or die "Cannot mkdir $work_dir: $!";

    # my $stage_dir = "$cwd/stage";
    #-d $stage_dir or mkdir $stage_dir or die "Cannot mkdir $stage_dir: $!";

    my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;

    # server config passed to script
    my $dat = { data_api => $data_api };
    my $sstring = encode_json($dat);
    my $params_to_app = Clone::clone($params);

    #
    # Write job description.
    #
    my $jdesc = "$cwd/jobdesc.json";
    open(JDESC, ">", $jdesc) or die "Cannot write $jdesc: $!";
    print JDESC JSON::XS->new->pretty(1)->encode($params_to_app);
    close(JDESC);
    my @cmd = ("p3-mauve", "--jfile", $jdesc, "--sstring", $sstring, "-o", $work_dir);

    warn Dumper(\@cmd, $params_to_app);


    print 'Running mauve...';
    my $ok = run(\@cmd);
    if (!$ok)
    {
    	die "Command failed: @cmd\n";
    }

    my @output_suffixes = (
        [qr/\.xmfa*/, "txt"],
        [qr/\.json*/, "json"]
    );

    my $outfile;
    opendir(D, $work_dir) or die "Cannot opendir $work_dir: $!";
    my @files = sort { $a cmp $b } grep { -f "$work_dir/$_" } readdir(D);

    for my $file (@files)
    {
        for my $suf (@output_suffixes)
        {
            if ($file =~ $suf->[0])
            {
                my $path = "$output_folder/$file";
                my $type = $suf->[1];

                $app->workspace->save_file_to_file(
                    "$work_dir/$file",
                    {},
                    "$output_folder/$file",
                    $type,
                    1,
                    (-s "$work_dir/$file" > 10_000 ? 1 : 0), # shock for larger files
                    $token
                );
            }
        }
    }

}
