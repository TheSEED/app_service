use Data::Dumper;
use strict;
use GenomeTypeObject;
use P3DataAPI;
use Cwd 'abs_path';
use Getopt::Long::Descriptive;
use JSON::XS;
use File::Slurp;
use File::Temp;
use File::Copy;
use IPC::Run;
use Clone 'clone';

use Bio::KBase::AppService::Circos;

my($opt, $usage) = describe_options("%c %o gto-file",
				    ["data-dir|d=s" => "Write configuration and data to this directory"],
				    ["output-svg=s" => "Write output svg file here"],
				    ["output-png=s" => "Write output png file here"],
				    ["truncate-small-contigs" => "If true, truncate display to remove small contigs below L90"],
				    ["subsystem-colors=s" => "Subsystem superclass color map file"],
				    ["specialty-genes=s" => "Specialty genes load file (json)"],
				    ["help|h" => "Show this help message"]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 1;

my $file = shift;

my $gto;
my $from_api;
if (-f $file)
{
    $gto = GenomeTypeObject->new({file => $file});
}
elsif ($file =~ /^\d+\.\d+$/)
{
    my $api = P3DataAPI->new();
    $from_api = 1;
    $gto = $api->gto_of($file);
    if (!$gto->{genome_quality_measure}->{genome_metrics})
    {
	my $m = $gto->metrics;
	$gto->{genome_quality_measure}->{genome_metrics} = $m;
    }
}
else
{
    die "Genome file $file not found\n";
}

my $data_dir;
if ($opt->data_dir)
{
    $data_dir = $opt->data_dir;
    -d $data_dir or die "Specified data directory $data_dir does not exist\n";
    $data_dir = abs_path($data_dir);
}
else
{
    $data_dir = File::Temp->newdir(CLEANUP => 0);
    print STDERR "Writing to tempdir $data_dir\n";
}

my $json = JSON::XS->new->pretty(1);

my $spgenes = {};

if ($opt->specialty_genes)
{
    my $dat = read_file($opt->specialty_genes);
    my $glist = $json->decode($dat);
    $spgenes->{$_->{patric_id}}->{$_->{property}} = $_ foreach @$glist;
}

my $color_map;

my $ss_colors;
if ($opt->subsystem_colors)
{
    $ss_colors = $opt->subsystem_colors;
}
else
{
    #
    # Try to create.
    #
    
    my $gto_file = $file;
    if ($from_api)
    {
	$gto_file = File::Temp->new();
	close($gto_file);
	my $clone = clone($gto);
	$clone->destroy_to_file("$gto_file");
    }
    $ss_colors = "$data_dir/ss_colors.json";
    my $ok = IPC::Run::run(["p3x-determine-subsystem-colors", "$gto_file"], ">", $ss_colors);
    $ok or die "Error running p3x-determine-subsystem-colors: $!";
}

if ($ss_colors)
{
    my $ss_color_txt = read_file($ss_colors);
    eval { $color_map = $json->decode($ss_color_txt); };
    if ($@)
    {
	die "Error parsing subsystem color map: $@";
    }
}

my $circos = Bio::KBase::AppService::Circos->new($gto, $data_dir, $color_map);

$circos->specialty_genes($spgenes) if $spgenes;

my $vars = $circos->generate_configuration($opt);

$circos->write_configs($vars);

#
# Run circos.
#

chdir($data_dir) or die "Cannot chdir $data_dir: $!";

my $ok = IPC::Run::run(["circos"]); # , ">", "circos.out", "2>", "circos.err");
if (!$ok)
{
    die "Error $! running circos";
}
	
if ($opt->output_png)
{
    copy("circos.png", $opt->output_png) or die "Error copying output: $!";
}

if ($opt->output_svg)
{
    copy("circos.svg", $opt->output_svg) or die "Error copying output: $!";
}

