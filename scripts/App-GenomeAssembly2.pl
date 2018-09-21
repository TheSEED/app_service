#
# The Genome Assembly application, version 2, using p3_assembly.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use POSIX;

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;

my $script = Bio::KBase::AppService::AppScript->new(\&process_reads);

my $download_path;

$script->donot_create_result_folder(1);
my $rc = $script->run(\@ARGV);

exit $rc;

sub process_reads {
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    my $token = $app->token();
    my $ws = $app->workspace();

    my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    $download_path = $tmpdir;

    my $asm_out = "$tmpdir/assembly";
    mkdir($asm_out) or die "cannot mkdir $tmpdir/assembly: $!";
    my $stage_dir = "$tmpdir/staging";
    mkdir($stage_dir) or die "cannot mkdir $tmpdir/staging: $!";
    
    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params);
    $readset->localize_libraries($stage_dir);

    my($ok, $errs) = $readset->validate($ws);

    if (!$ok)
    {
	die "Reads as defined in parameters failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    $readset->stage_in($ws);

    my @params = $readset->build_p3_assembly_arguments();
    my @cmd = ("p3_assembly", "-o", $asm_out, @params);

    print "Start assembler: @cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	die "Assembler failed with rc=$rc";
    }

    return;
    my $output_folder = $app->result_folder();

    my @outputs;
for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$filename", $type, 1,
					       (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       $token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

}


sub localize
{
    my($path, $download_list) = @_;
    return unless $path;
    my $file = $download_path . "/" . basename($path);
    push(@$download_list, [$path, $file]);
    return $file;
}
