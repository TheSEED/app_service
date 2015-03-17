#
# The Differential Expression application.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AuthToken;
use strict;
use Data::Dumper;
use File::Basename;
use LWP::UserAgent;
use JSON::XS;
use IPC::Run qw(run);

my $script = Bio::KBase::AppService::AppScript->new(\&process_diffexp);

$script->run(\@ARGV);

sub process_diffexp
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc diffexp ", Dumper($app_def, $raw_params, $params);

    my $xfile = $params->{xfile};
    my $mfile = $params->{mfile};
    my $ustring = $params->{ustring};

    my $token = $app->token();
    my $output_folder = $app->result_folder();

    my $xfile_tmp = basename($xfile);
    my $sfile_tmp = "sstr.$$";
    my $ufile_tmp = "ustr.$$";

    open(my $xfile_fh, ">", $xfile_tmp) or die "Cannot open $xfile_tmp:$!";
    open(my $sstring_fh, ">", $sfile_tmp) or die "Cannot open $sfile_tmp:$!";
    open(my $ustring_fh, ">", $ufile_tmp) or die "Cannot open $sfile_tmp:$!";

    my @files = ([$xfile, $xfile_fh]);
    
    my $mfile_tmp;
    my $mfile_fh;
    my @mfile_arg;
    if ($mfile)
    {
	$mfile_tmp = basename($mfile);
	open($mfile_fh, ">", $mfile_tmp) or die "Cannot open $mfile_tmp:$ !";
	push(@files, [$mfile, $mfile_fh]);
	push(@mfile_arg, "--mfile", $mfile_tmp);
    }

    eval {
	$app->workspace->copy_files_to_handles(1, $token, \@files);
    };
    if ($@)
    {
	die "Workspace download failed: $@";
    }

    close($xfile_fh);
    close($mfile_fh) if $mfile_fh;

    my $dat = { data_api => Bio::KBase::AppService::AppConfig->data_api_url };
    my $sstring = encode_json($dat);

    print $sstring_fh $sstring;
    print $ustring_fh $ustring;

    close($sstring_fh);
    close($ustring_fh);

    my $out = "out.dir";
    -d $out || mkdir($out) || die "Cannot mkdir $out: $!";
    my @cmd = ("expression_transform",
	       "--xfile", $xfile_tmp,
	       @mfile_arg,
	       "--output_path", $out,
	       "--ufile", $ufile_tmp,
	       "--sfile", $sfile_tmp);

    my $ok = run(\@cmd);
    if (!$ok)
    {
	die "Command failed: @cmd\n";
    }


    my @outputs = (["experiment.json", "diffexp_experiment"],
		   ["expression.json", "diffexp_expression"],
		   ["mapping.json", "diffexp_mapping"],
		   ["sample.json", "diffexp_sample"]);
    for my $out_ent (@outputs)
    {
	my($ofile, $type) = @$out_ent;
	if (-f "$out/$ofile")
	{
	    $app->workspace->save_file_to_file("$out/$ofile", {}, "$output_folder/$ofile", $type, 1,
					       (-s "$out/$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       $token);
	}
	else
	{
	    warn "Missing desired output file $ofile\n";
	}
    }
}
