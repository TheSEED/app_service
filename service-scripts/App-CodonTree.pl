#
# App wrapper for the codon tree application.
# Initial version that does not internally fork and report output; instead
# is designed to be executed by p3x-app-shepherd.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::CodonTreeReport;
use P3DataAPI;
use IPC::Run;
use Cwd;
use File::Path 'make_path';
use strict;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use File::Temp;
use JSON::XS;
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o app-definition.json param-values.json",
				    ["preflight=s" => "Run app preflight and write results to given file."],
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 2;
my $app_def_file = shift;
my $param_values_file = shift;

my $app = Bio::KBase::AppService::AppScript->new();

my $params = $app->preprocess_parameters($app_def_file, $param_values_file);
$app->initialize_workspace();

if ($opt->preflight)
{
    preflight($app, $params, $opt->preflight);
    exit 0;
}

$app->setup_folders();

#
# Set up options for tool and database.
#

my @cmd;
my @options;

@cmd = ("p3x-build-codon-tree");

#
# If we are running under Slurm, pick up our memory and CPU limits.
#
my $mem = $ENV{P3_ALLOCATED_MEMORY};
my $cpu = $ENV{P3_ALLOCATED_CPU};

if ($cpu)
{
    push(@options, "--threads", $cpu);
}


my($genome_ids, $opt_genome_ids, $genome_names) = verify_genome_ids($app, $params);

my $here = getcwd();
open(F, ">", "$here/genomes.in") or die "Cannot write $here/genomes.in: $!";
print F "$_\n" foreach @$genome_ids;
close(F);

open(F, ">", "$here/opt_genomes.in") or die "Cannot write $here/opt_genomes.in: $!";
print F "$_\n" foreach @$opt_genome_ids;
close(F);

push(@options, "--genomeIdsFile", "$here/genomes.in");
#push(@options, "--outgroupIdsFile", "$here/opt_genomes.in");

my $n_genes = $params->{number_of_genes};
my $bootstraps = $params->{bootstraps};
my $max_missing = $params->{max_genomes_missing};
my $max_allowed_dups = $params->{max_allowed_dups};

my $raxml = "raxmlHPC-PTHREADS-SSE3";

my $out_dir = "$here/output";
make_path($out_dir);

my @figtrees = grep { -f $_ } sort { $b <=> $a }  <$ENV{KB_RUNTIME}/FigTree*/lib/figtree.jar>;
my @figtree_jar;
if (@figtrees)
{
    @figtree_jar = ("--pathToFigtreeJar", $figtrees[0]);
}
else
{
    warn "Cannot find figtree in $ENV{KB_RUNTIME}\n";
}

push(@options,
     @figtree_jar,
     '--outputBase', $params->{output_file},
     '--maxGenes', $n_genes,
     '--bootstrapReps', $bootstraps,
     '--maxGenomesMissing', $max_missing,
     '--maxAllowedDups', $max_allowed_dups,
#     '--debugMode',
     '--raxmlExecutable', $raxml,
     '--outputDirectory', $out_dir);

print Dumper(\@cmd, \@options);

my $ok = 1;
if (1)
{
    $ok = IPC::Run::run([@cmd, @options]);
}
my $svg_tree;

save_output_files($app, $out_dir);
$app->write_results(undef, $ok);

#
# Run preflight to estimate size and duration.
#
sub preflight
{
    my($app, $params, $preflight_out) = @_;

    my($genome_ids, $opt_genome_ids) = verify_genome_ids($app, $params);

    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => 0,
	storage => 0,
    };
    open(PF, ">", $preflight_out) or die "Cannot write preflight file $preflight_out: $!";
    my $js = JSON::XS->new->pretty(1)->encode($pf);
    print PF $js;
    close(PF);
}

sub verify_genome_ids
{
    my($app, $params) = @_;

    my $glist = $params->{genome_ids};
    my $opt_glist = $params->{optional_genome_ids};
    $opt_glist = [] unless ref($opt_glist) eq 'ARRAY';

    if (ref($glist) ne 'ARRAY' || @$glist == 0)
    {
	die "The CodonTree application requires at least one genome to be specified\n";
    }

    my $api = P3DataAPI->new;
    my $names = $api->genome_name([@$glist, @$opt_glist]);

    my(@bad, @opt_bad);
    for my $g (@$glist)
    {
	if (exists($names->{$g}))
	{
	    print "Processing genome $g $names->{$g}->[0]\n";
	}
	else
	{
	    push(@bad, $g);
	}
    }
    if (@bad)
    {
	warn "Cannot find the following genomes to process: @bad\n";
    }
    for my $g (@$opt_glist)
    {
	if (exists($names->{$g}))
	{
	    print "Processing optional genome $g $names->{$g}->[0]\n";
	}
	else
	{
	    push(@opt_bad, $g);
	}
    }
    
    if (@opt_bad)
    {
	warn "Cannot find the following optional genomes to process: @opt_bad\n";
    }
    if (@bad || @opt_bad)
    {
	die "CodonTree cannot continue due to missing genome errors\n";
    }
    return($glist, $opt_glist, $names);
}

sub save_output_files
{
    my($app, $output) = @_;
    
    my %suffix_map = (fastq => 'reads',
		      txt => 'txt',
		      png => 'png',
		      svg => 'svg',
		      nwk => 'nwk',
		      out => 'txt',
		      err => 'txt',
		      html => 'html');

    my @suffix_map = map { ("--map-suffix", "$_=$suffix_map{$_}") } keys %suffix_map;

    if (opendir(my $dh, $output))
    {
	while (my $p = readdir($dh))
	{
	    next if $p =~ /^\./;
	    
	    my @cmd = ("p3-cp", "-r", @suffix_map, "$output/$p", "ws:" . $app->result_folder);
	    print "@cmd\n";
	    my $ok = IPC::Run::run(\@cmd);
	    if (!$ok)
	    {
		warn "Error $? copying output with @cmd\n";
	    }
	}
	closedir($dh);
    }
    else
    {
	warn "Output directory $output does not exist\n";
    }
}
