
#
# Given a file of contigs, compute a set of ingroup and outgroup genomes
# for use with the tree service.
#
# This requires a mash sketch of the set of genomes to be used as a reference
# This script takes that as a required input.
# 
# ./neighbor_masher.sh -i /vol/patricftp/ftp/genomes/83332.12/83332.12.fna -o /vol/patric3/production/data/trees/listOfRepRefGenomeFnaFiles.txt.msh -c 2 -e 3
#

use strict;
use Getopt::Long::Descriptive;
use File::Temp;
use File::Copy;
use Cwd qw(abs_path getcwd);

my($opt, $usage) = describe_options("%c %o reference-sketch contigs-file ingroup-file outgroup-file",
				    ["ingroup-size|I=n" => "Number of ingroup genomes to find", { default => 10 }],
				    ["outgroup-size|O=n"=> "Number of outgroup genomes to find", { default => 3 }],
				    ["parallel|p=i"	=> "Number of processors to use for mash", { default => 4 }],
				    ["kmer-size|k=i"	=> "Kmer size to use (must match the sketch)", { default => 15 }],
				    ["sketch-size|s=i"	=> "Sketch size to use (must match the sketch)", { default => 100000 }],
				    ["rooted-tree|r=s"	=> "Save the rooted tree in this file"],
				    ["ingroup-tree|g=s" => "Save the ingroup tree in this file"],
				    ["help|h"		=> "Show this help message"]);
				     
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 4;

my $ref_sketch = shift;
my $contigs = shift;
my $ingroup = shift;
my $outgroup = shift;

if (-e $ingroup && ! -f $ingroup)
{
    die "Ingroup file $ingroup exists but is not a plain file\n";
}

if (-e $outgroup && ! -f $outgroup)
{
    die "Outgroup file $outgroup exists but is not a plain file\n";
}

-s $ref_sketch or die "Reference sketch $ref_sketch not readable\n";
-s $contigs or die "Contigs file $contigs not readable\n";

$ref_sketch = abs_path($ref_sketch);
$contigs = abs_path($contigs);

my $tmp = File::Temp->newdir(CLEANUP => 1);

#
# The pepr code writes temporaries to the current directory.
# We chdir to our tempdir to keep from stomping on what might be here.
#

my $here = getcwd();
chdir($tmp) or die "Cannot chdir $tmp: $!";

#
# We need to find the jarfiles. They live in the PATRIC environment
# in $KB_RUNTIME/pepr/lib
#

my $jar_dir = "$ENV{KB_RUNTIME}/pepr/lib";
my @jars = ('pepr.jar', 'log4j.jar');
my @jar_paths;
for my $jar (@jars)
{
    my $jp = "$jar_dir/$jar";
    if (! -f $jp)
    {
	die "Cannot find jarfile $jp";
    }
    push(@jar_paths, $jp);
}

my $run_name = "$tmp/run";

my @cmd = ("java",
	   "-cp", join(":", @jar_paths),
	   "edu.vt.vbi.ci.util.NeighborMasher",
	   "-p", $opt->parallel,
	   "-mash", "mash",
	   "-ingroup", $contigs,
	   "-outgroup_sketch", $ref_sketch,
	   "-outgroup_count", $opt->outgroup_size,
	   "-expand_ingroup", $opt->ingroup_size,
	   "-k", $opt->kmer_size,
	   "-s", $opt->sketch_size,
	   "-run_name", $run_name);
print "@cmd\n";
my $rc = system(@cmd);
if ($rc != 0)
{
    die "NeighborMasher run failed with $rc: @cmd";
}

#
# Move back to our original directory and copy desired output files.
#

chdir($here);
copy("${run_name}_ingroup.txt", $ingroup) or die "Cannot copy ${run_name}_ingroup.txt to $ingroup: $!";
copy("${run_name}_outgroup.txt", $outgroup) or die "Cannot copy ${run_name}_outgroup.txt to $outgroup: $!";

my $tbase = "_k" . $opt->kmer_size . "_s" . $opt->sketch_size;

if ($opt->ingroup_tree)
{
    copy("${run_name}${tbase}_ingroup_nj.nwk", $opt->ingroup_tree)
	or die "Cannot copy ${run_name}${tbase}_ingroup_nj.nwk to " . $opt->ingroup_tree . ": $!";
}

if ($opt->rooted_tree)
{
    copy("${run_name}${tbase}_rooted_nj.nwk", $opt->rooted_tree)
	or die "Cannot copy ${run_name}${tbase}_rooted_nj.nwk to " . $opt->rooted_tree . ": $!";
}
