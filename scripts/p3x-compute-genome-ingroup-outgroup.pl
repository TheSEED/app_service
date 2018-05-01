
#
# Given a file of contigs, compute a set of ingroup and outgroup genomes
# for use with the tree service.
#
# This requires a mash sketch of the set of genomes to be used as a reference
# This script takes that as a required input.
# 
# ./neighbor_masher.sh -i /vol/patricftp/ftp/genomes/83332.12/83332.12.fna -o /vol/patric3/production/data/trees/listOfRepRefGenomeFnaFiles.txt.msh -c 2 -e 3
#
# We have two methods. First is Eric Nordberg's NeighborMasher from the PEPR distribution; due to
# issues we are not defaulting to that.
#
# The second is a bog-standard search agains the same mash database for closest hits.
#

use strict;
use Getopt::Long::Descriptive;
use File::Temp;
use File::Copy;
use Cwd qw(abs_path getcwd);
use IPC::Run;
use GenomeTypeObject;
use Bio::KBase::AppService::AppConfig qw(mash_reference_sketch);

my(@methods) = qw(mash neighbor_masher);

my($opt, $usage) = describe_options("%c %o contigs-file ingroup-file [outgroup-file]",
				    ["reference-sketch|R=s" => "Reference sketch file", { default => mash_reference_sketch }],
				    ["method|m=s"       => "Group computation method (defaults to mash)", { default => 'mash' }],
				    ["mash-threshold=s" => "Mash distance threshold", { default => 0.5 }],
				    ["ingroup-size|I=n" => "Number of ingroup genomes to find", { default => 10 }],
				    ["outgroup-size|O=n"=> "Number of outgroup genomes to find", { default => 0 }],
				    ["parallel|p=i"	=> "Number of processors to use for mash", { default => 4 }],
				    ["kmer-size|k=i"	=> "Kmer size to use (must match the sketch)", { default => 15 }],
				    ["sketch-size|s=i"	=> "Sketch size to use (must match the sketch)", { default => 100000 }],
				    ["rooted-tree|r=s"	=> "Save the rooted tree in this file"],
				    ["ingroup-tree|g=s" => "Save the ingroup tree in this file"],
				    ["logfile|l=s"      => "Write log to this file"],
				    ["help|h"		=> "Show this help message"]);
				     
print($usage->text), exit 0 if $opt->help;
die($usage->text) if ($opt->outgroup_size && @ARGV != 3) || (!$opt->outgroup_size && @ARGV != 2);

my $ref_sketch = $opt->reference_sketch;

my $contigs = shift;
my $ingroup = shift;
my $outgroup = shift;

my $method = $opt->method;
if ((grep { $_ eq $method } @methods) == 0)
{
    die "Invalid method '$method' chosen; valid methods are @methods";
}

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
# Check the contigs to see if they appear to be contigs.
# Include at some point a call to a more comprehensive checker.
#
if (!is_fasta($contigs))
{
    #
    # Assume it's a GTO, try to open and 
    #
    my $gto;
    eval {
	$gto = GenomeTypeObject->new({ file => $contigs });
    };
    if (!$gto)
    {
	die "Cannot parse $contigs as contigs file or as genome object";
    }
    $contigs = "$tmp/contigs.fa";
    $gto->write_contigs_to_file($contigs);
}

#
# The pepr code writes temporaries to the current directory.
# We chdir to our tempdir to keep from stomping on what might be here.
#

my $logfile = abs_path($opt->logfile) if $opt->logfile;
$logfile //= "neighbor_masher.log";

my $here = getcwd();
chdir($tmp) or die "Cannot chdir $tmp: $!";

if ($method eq 'neighbor_masher')
{
    run_pepr($contigs);
}
elsif ($method eq 'mash')
{
    run_mash($contigs);
}
else
{
    die "Unknown method $method\n";
}

sub run_mash
{
    my($contigs) = @_;

    my @cmd = ("mash", "dist", "-d", $opt->mash_threshold, $ref_sketch, $contigs);

    my $h = IPC::Run::start(\@cmd, '|',
			    ['sort', '-k3n'],
			    '>pipe', \*MASH);
    $h or die "Could not run mash pipeline @cmd: $!";

    my @genomes;
    #
    # Making assumptions about format of mash data. First string that looks
    # like a genome id is the genome id.
    while (<MASH>)
    {
	if (/(\d+\.\d+)/)
	{
	    push(@genomes, $1);
	}
	last if @genomes >= $opt->ingroup_size;
    }
    close(MASH);
    $h->finish();

    chdir($here);
    
    open(IG, ">", $ingroup) or die "Cannot write $ingroup: $!";
    print IG "$_\n" foreach @genomes;
    close(IG);
}

sub run_pepr
{
    my($contigs) = @_;

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
	       "-Dlogfile.name=$logfile",
	       "-Dlog4j.configuration=file:$jar_dir/log4j.properties",
	       "edu.vt.vbi.ci.util.NeighborMasher",
	       "-p", $opt->parallel,
	       "-mash", "mash",
	       "-ingroup", $contigs,
	       "-outgroup_sketch", $ref_sketch,
	       "-expand_ingroup", $opt->ingroup_size,
	       "-k", $opt->kmer_size,
	       "-s", $opt->sketch_size,
	       "-run_name", $run_name);
    
    if ($opt->outgroup_size)
    {
	push(@cmd, "-outgroup_count", $opt->outgroup_size);
    }
    else
    {
	push(@cmd, "-ingroup_only");
    }
    
    print "@cmd\n";
    my $rc = system(@cmd);
    if ($rc != 0)
    {
	#
	# Get out of our temp dir so it can be removed.
	chdir($here);
	die "NeighborMasher run failed with $rc: @cmd";
    }
    
    #
    # Move back to our original directory and copy desired output files.
    #
    
    chdir($here);
    copy("${run_name}_ingroup.txt", $ingroup) or die "Cannot copy ${run_name}_ingroup.txt to $ingroup: $!";
    if ($opt->outgroup_size)
    {
	copy("${run_name}_outgroup.txt", $outgroup) or die "Cannot copy ${run_name}_outgroup.txt to $outgroup: $!";
    }
    
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
}

sub is_fasta
{
    my($contigs) = @_;
    open(my $fh, "<", $contigs) or die "Cannot open contigs file $contigs: $!";
    my $l = <$fh>;
    if ($l !~ /^>\S+/)
    {
	return 0;
    }
    $l = <$fh>;
    if ($l !~ /[actg]+/i)
    {
	return 0;
    }
    return 1;
}
    
