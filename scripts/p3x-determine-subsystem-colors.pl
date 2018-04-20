#
# Given a GTO with subsystem information, compute
# the colormap for rendering subsystem toplevel classifications.
#
# We use a standard map hardcoded here and assign colors based
# the number of pegs in each of the classifications.
#

use strict;
use Getopt::Long::Descriptive;
use JSON::XS;
use Data::Dumper;

use GenomeTypeObject;

my $color_map = [
		     "#1f77b4",
		     "#ff7f0e",
		     "#2ca02c",
		     "#d62728",
		     "#9467bd",
		     "#8c564b",
		     "#e377c2",
		     "#7f7f7f",
		     "#bcbd22",
		     "#17becf",
		     "#aec7e8",
		     "#ffbb78",
		     "#98df8a",
		     "#ff9896",
		     "#c5b0d5",
		     "#c49c94",
		     "#f7b6d2",
		     "#c7c7c7",
		     "#dbdb8d",
		     "#9edae5"
		 ];


my($opt, $usage) = describe_options("%c %o gto-file",
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) unless @ARGV == 1;

my $gto_file = shift;

my $gto = GenomeTypeObject->new({file => $gto_file});
$gto or die "Cannot load gto from file $gto_file: $!";

my $summary = $gto->{subsystem_summary};

if (!$summary)
{
    $summary = {};
    for my $ss (@{$gto->{subsystems}})
    {
	my $superclass = $ss->{classification}->[0];
	my $count = 0;
	for my $binding (@{$ss->{role_bindings}})
	{
	    $count += @{$binding->{features}};
	}
	$summary->{$superclass} += $count;
    }
}

my @sorted = sort { $summary->{$b} <=> $summary->{$a} } keys %$summary;

my $color_index = 0;
my $n_colors = @$color_map;
my $res = {};
for my $superclass (@sorted)
{
    my $color = $color_map->[$color_index];
    $color_index = ($color_index + 1 % $n_colors);
    $res->{$superclass} = $color;
}

my $json = JSON::XS->new->pretty(1);

print $json->encode($res);
