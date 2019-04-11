use Data::Dumper;
use strict;
use Getopt::Long::Descriptive;
use JSON::XS;
use File::Slurp;
use File::Temp;
use File::Basename;

#
# Helper script for offloading binning assembly to cluster.
#

my($opt, $usage) = describe_options("%c %o output-ws-path < params",
				    ["threads=i", "thread count", { default => 12 }],
				    ["memory=i", "memory use in GB", { default => 128 }],
				    ["help|h" => "show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 1;

my $output_ws = shift;

my $txt = read_file(\*STDIN);

my $doc = decode_json($txt);

print Dumper($doc);

my $workdir = File::Temp->newdir();

my($read1, $read2);
if ($doc->{read1})
{
    my $base1 = basename($doc->{read1});
    $read1 = "$workdir/$base1";
    run("p3-cp", "ws:" . $doc->{read1}, $read1);

    my $base2 = basename($doc->{read2});
    $read2 = "$workdir/$base2";
    run("p3-cp", "ws:" . $doc->{read2}, $read2);
}
print "reads: $read1 $read2\n";

#
# There is a bug in p3x-assembly with the pairing up of paired end read
# files based on filenames. For now we'll submit using the
# --illumina flag to ensure the pairs get set correctly for binning.
# old: "--anon", $read1, $read2,
#

my(@cmd) = ("p3x-assembly",
	    "--meta",
	    "--illumina", join(":", $read1, $read2),
	    "--runTrimmomatic",
	    "-o", $workdir,
	    "--threads", $opt->threads,
	    "--memory", $opt->memory,
	    );

print "@cmd\n";

my $rc = system(@cmd);

if ($rc != 0)
{
    die "Failed to run spades: rc=$rc\n";
}

#
# Run is done, copy contigs and logs back to workspace.
#

my @map = ("-m", "fasta=contigs", "-m", "log=txt");
my @files = qw(contigs.fasta spades.log params.txt p3x-assembly.log);
for my $f (@files)
{
    if (-f "$workdir/$f")
    {
	my $rc = system("p3-cp", @map, "$workdir/$f", "ws:$output_ws/$f");
	if ($rc != 0)
	{
	    warn "Error $rc copying $workdir/$f to $output_ws/$f\n";
	}
    }
}

sub run
{
    my(@cmd) = @_;
    my $rc = system(@cmd);
    die "@cmd failed with $rc\n" unless $rc == 0;
}
