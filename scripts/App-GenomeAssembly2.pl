#
# The Genome Assembly application, version 2, using p3_assembly.
#

=head1 NAME

App-GenomeAssembly2 - assemble a set of reads

=head1 SYNOPSIS

    App-GenomeAssembly [--preflight] service-url app-definition parameters

=head1 DESCRIPTION

Assemble a set of reads.

=head2 PREFLIGHT INFORMATION

On a preflight request, we will generate a JSON object with the following
key/value pairs:

=over 4

=item ram

Requested memory. For standard run we request 128GB.

=item cpu

Requested CPUs.
    
=cut

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use POSIX;

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;

my $script = Bio::KBase::AppService::AppScript->new(\&assemble, \&preflight);

my $download_path;

$script->donot_create_result_folder(1);
my $rc = $script->run(\@ARGV);

exit $rc;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    print STDERR "preflight genome ", Dumper($params, $app);

    my $token = $app->token();
    my $ws = $app->workspace();

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params);

    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($ws);

    if (!$ok)
    {
	die "Reads as defined in parameters failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    print STDERR "comp=$comp_size uncomp=$uncomp_size\n";

    my $est_comp = $comp_size + 0.75 * $uncomp_size;
    $est_comp /= 1e6;
    #
    # Estimated conservative rate is 10sec/MB for compressed data under 1.5G, 4sec/GM for data over that.
    my $est_time = int($est_comp < 1500 ? (10 * $est_comp) : (4 * $est_comp));

    # Estimated compressed storage based on input compressed size, converted at 75% compression estimate.
    my $est_storage = int(1.3e6 * $est_comp / 0.75);

    #
    # We just fix the cpu and ram
    #
    my $est_cpu = 12;
    my $est_ram = "128G";

    return {
	cpu => $est_cpu,
	memory => $est_ram,
	runtime => $est_time,
	storage => $est_storage,
    };
}

sub assemble
{
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

    my $log = "$tmpdir/p3_assembly.log";
    my @params = $readset->build_p3_assembly_arguments();

    #
    # If we are running under Slurm, pick up our memory and CPU limits.
    #
    my $mem = $ENV{P3_ALLOCATED_MEMORY};
    my $cpu = $ENV{P3_ALLOCATED_CPU};

    if ($mem)
    {
	my $bytes;
	my %fac = (k => 1024, m => 1024*1024, g => 1024*1024*1024, t => 1024*1024*1024*1024 );
	my($val, $suffix) = $mem =~ /^(.*)([mkgt])$/i;
	if ($suffix)
	{
	    $bytes = $val * $fac{lc($suffix)};
	}
	else
	{
	    $bytes = $mem;
	}
	$mem = int($bytes / (1024*1024*1024));
	push(@params, "-m", "$mem);
    }

    push(@params, "-t", $cpu) if $cpu;

    my @cmd = ("p3x-assembly",
	       "--logfile", $log,
	       "-o", $asm_out,
	       @params);

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
