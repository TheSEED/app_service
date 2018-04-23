package Bio::KBase::AppService::Circos;

#
# Implementation code for the Circos circular genome creation module.
#
# The constructor is given a data directory into which the various
# data and configuration files are written. This will typically be a temporary
# directory but not necessarily; if the calling code desires to leave
# the data files around for the user to manipulate it may. The Circos
# module will not remove the data files.
#
# The specialty genes hash is of the form $spgenes->{patric-id}->{property-name} = { property data };
#

use Data::Dumper;
use strict;
use GenomeTypeObject;
use P3DataAPI;
use Getopt::Long::Descriptive;
use JSON::XS;
use File::Slurp;
use IPC::Run;
use Module::Metadata;
use Template;
use File::Basename;

use base 'Class::Accessor';
__PACKAGE__->mk_accessors(qw(gto data_dir subsystem_color_map json chr_color gc_window specialty_genes));

#
# Hardcoded colors to match PATRIC current state.
#

our %track_color = (fwd => 'lgrey',
		    rev => 'lgrey',
		    misc => '131,59,118',
		    amr => '255,165,0',
		    vf => '0,0,255');

sub new
{
    my($class, $gto, $data_dir, $subsystem_color_map) = @_;

    -d $data_dir or die "Bio::KBase::AppService::Circos: data directory $data_dir does not exist";

    my $self = {
	gto => $gto,
	data_dir => $data_dir,
	subsystem_color_map => $subsystem_color_map,
	json => JSON::XS->new->pretty(1),
	gc_window => 2000,
	chr_color => "0,15,125",
    };

    bless $self, $class;
    $self->transform_color_map();

    return $self;
}

sub transform_color_map
{
    my($self) = @_;

    #
    # Transform colormap to the syntax circos wants
    #
    my $color_map = $self->subsystem_color_map;
    if (ref($color_map) eq 'HASH')
    {
	for my $ent (values %$color_map)
	{
	    my @v = $ent =~ /^\#(..)(..)(..)/;
	    $ent = join(",", map { hex($_) } @v) if @v;
	}
    }
}

sub generate_configuration
{
    my($self, $opt) = @_;

    my %template_vars;
    
    my %set;
    
    my $color_map = $self->subsystem_color_map;
    my %feature_to_classification;

    #
    # Read subsystem data and compute feature=>classification mapping
    #

    my $gto = $self->gto;
    for my $ss (@{$gto->{subsystems}})
    {
	my $superclass = $ss->{classification}->[0];

	for my $binding (@{$ss->{role_bindings}})
	{
	    $feature_to_classification{$_} = $superclass foreach @{$binding->{features}};
	}
    }

    ###############################
    #
    # Write karyotype band and compute GC bands.
    #

    my $kt_file = $template_vars{karyotype_file} = $self->data_dir . "/karyotype.txt";
    open(K, ">", $kt_file) or die "Cannot write $kt_file: $!";

    my $gc_file = $self->data_dir . "/hdata.gc";
    my $skew_file = $self->data_dir . "/hdata.skew";
    open(GC, ">", $gc_file) or die "Cannot write $gc_file: $!";
    open(SKEW, ">", $skew_file) or die "Cannot write $skew_file: $!";

    my $gc_plot = {
	background => '235,212,244',
	params => {
	    max_gap => '1u',
	    file => $gc_file,
	    color => 'vdgrey',
	    min => 0,
	    r0 => '0.31r',
	    r1 => '0.50r',
	},
	axes => [{
	    color => 'dgrey',
	    thickness => 1,
	    spacing => 0.25,
	}]
    };
    my $skew_plot = {
	background => '243,205,160',
	params => {
	    max_gap => '1u',
	    file => $skew_file,
	    color => 'black',
	    min => -0.5,
	    max => 0.5,
	    r0 => '0.10r',
	    r1 => '0.30r',
	},
	axes => [{
	    color => 'dgrey',
	    thickness => 1,
	    spacing => 0.25,
	}, {
	    color => 'black',
	    thickness => 1,
	    position => 0,
	}],
    };
    my $plots = $template_vars{plots} = [$gc_plot, $skew_plot];

    my $ctg_index = 0;

    my @contigs = @{$gto->contigs};
    my $cutoff = @contigs;
    if ($opt->truncate_small_contigs && @contigs > 100)
    {
	$cutoff = $gto->{genome_quality_measure}->{genome_metrics}->{L90};
    }

    $template_vars{chromosome_spacing} = $cutoff > 100 ? "0.001r": "0.005r";
    
    my %contig_length;
    $contig_length{$_->{id}} = length($_->{dna}) foreach @contigs;

    #
    # If our contig IDs look like genbank IDs, sort them by id.
    # Otherwise sort by descending length.
    #

    if (0 && $contigs[0]->{id} =~ /^NC/)
    {
	@contigs = sort { $a->{id} cmp $b->{id} } @contigs;
    }
    else
    {
	@contigs = sort { $contig_length{$b->{id}} <=> $contig_length{$a->{id}} } @contigs;
    }

    

    #
    # We also compute the list of chromosomes (contigs) for which
    # we will eliminate tick labels.
    #
    my @no_tick_labels;

    for my $contig (@contigs)
    {
	next if $ctg_index++ > $cutoff;

	my($seq, $id) = @$contig{'dna', 'id'};
	
	my $len = $contig_length{$id};

	print K "chr - $id $id 0 " . ($len - 1) . " " . $self->chr_color . "\n";

	if ($len < 100000)
	{
	    push(@no_tick_labels, $id);
	}
	
	for (my $start = 0; $start < $len; $start += $self->gc_window)
	{
	    my $str = substr($seq, $start, $self->gc_window);
	    my $gcount = $str =~ tr/Gg//;
	    my $ccount = $str =~ tr/Cc//;
	    
	    my $l = length($str);
	    my $gpc = $gcount + $ccount;
	    my $gc = $gpc / $l;
	    my $skew = ($gpc == 0) ? 0 : ($gcount - $ccount) / $gpc;
	    
	    my $end = $start + $l - 1;
	    print GC "$id $start $end $gc\n";
	    print SKEW "$id $start $end $skew\n";
	}
    }

    if (@no_tick_labels)
    {
	$template_vars{no_tick_labels} = join(";", map { "-$_" } @no_tick_labels);
    }
    
    close(GC);
    close(SKEW);
    close(K);


    ###############################
    #
    # Generate highlights.
    #
    
    #
    # If we weren't provided with specialty gene data, try to load via API.
    #

    my $sp_genes = $self->specialty_genes;
    if (!$sp_genes)
    {
	$sp_genes = {};
	my $api = P3DataAPI->new();
	my @sp = eval { $api->query("sp_gene",
				    ["eq", "genome_id", $gto->{id}],
				    ["select", "patric_id", "property"]); };
	$sp_genes->{$_->{patric_id}}->{$_->{property}} = $_ foreach @sp;
    }
    
    my $hl_list = $template_vars{highlights} = [];
    my %hl;
    my %hl_fh;
    my @hl_tracks = qw(fwd rev misc amr vf );
    my $r_width = 0.09;
    my $r_gap = 0.01;
    my $r_cur = 1.0;
    for my $hl_track (@hl_tracks)
    {
	my $f = $self->data_dir . "/hdata.$hl_track";
	open(my $fh, ">", $f);
	$hl_fh{$hl_track} = $fh;

	my $r1 = $r_cur - $r_gap;
	my $r0 = $r1 - $r_width;
	$r_cur = $r0;
	$hl{$hl_track} = {
	    file => $f,
	    r0 => "${r0}r",
	    r1 => "${r1}r",
	    fill_color => $track_color{$hl_track},
	};
	push(@$hl_list, $hl{$hl_track});
    }

    my %fh;
    $fh{'+'} = $hl_fh{fwd};
    $fh{'-'} = $hl_fh{rev};

 FEATURE:
    for my $feature ($gto->features)
    {
	my($min, $max, $ctg, $strand) = feature_bounds($feature);
	my $fh;
	my $id = $feature->{id};
	
	my $ss_color;
	if (my $superclass = $feature_to_classification{$id})
	{
	    $ss_color = $color_map->{$superclass};
	}
	else
	{
	    # Default to non-ss background
	    # $ss_color = $color_map->{""};
	}
	
	if ($feature->{type} eq 'CDS')
	{
	    $fh = $fh{$strand};
	}
	else
	{
	    $fh = $hl_fh{misc};
	}
	my $dat = "$ctg\t$min\t$max";
	
	if ($ss_color)
	{
	    print $fh "$dat fill_color=$ss_color\n";
	}
	else
	{
	    print $fh "$dat\n";
	}
	if ($sp_genes->{$id}->{'Antibiotic Resistance'})
	{
	    print { $hl_fh{amr} } "$dat\n";
	}
	if ($sp_genes->{$id}->{'Virulence Factor'})
	{
	    print { $hl_fh{vf} } "$dat\n";
	}
    }
    close($_) foreach values %hl_fh;

    $template_vars{ticks_conf_file} = $self->data_dir . "/ticks.conf";

    return \%template_vars;
}

sub write_configs
{
    my($self, $vars) = @_;

    #
    # Expand and write the templated configuration files.
    #

    my $templ = Template->new(ABSOLUTE => 1);

    my $mod_path = Module::Metadata->find_module_by_name(__PACKAGE__);
    my $template_path = dirname($mod_path) . "/templates";

    for my $config_name (qw(circos.conf ticks.conf))
    {
	my $tt_file = "$template_path/${config_name}.tt";
	-f $tt_file or die "Template file $tt_file does not exist";

	my $out_file = $self->data_dir . "/$config_name";
	if (open(my $out_fh, ">", $out_file))
	{
	    $templ->process($tt_file, $vars, $out_fh)
		or die "Error processing template $tt_file: " . $templ->error();
	    close($out_fh);
	}
	else
	{
	    die "Cannot write $out_file: $!";
	}
    }
}

sub feature_bounds
{
    my($feature) = @_;
    my $l = $feature->{location};
    my($fctg, $fstart, $fstrand, $flen) = @{$l->[0]};
    
    my($min, $max) = bounds($l->[0]);
    
    for my $elt (@$l)
    {
	my($ctg, $start, $strand, $len) = @$elt;
	if ($ctg ne $fctg || $strand ne $fstrand)
	{
	    warn "Invalid feature (strand/contig doesn't match): " . Dumper($feature);
	    next;
	}
	($min, $max) = extend_bounds($min, $max, $elt);
    }
    return($min, $max, $fctg, $fstrand);
}

sub bounds
{
    my($l) = @_;
    my($ctg, $start, $strand, $len) = @$l;
    my($min, $max);
    if ($strand eq '+')
    {
	$min = $start;
	$max = $start + $len - 1;
    }
    else
    {
	$min = $start - $len + 1;
	$max = $start;
    }
    return($min, $max);
}

sub extend_bounds
{
    my($bmin, $bmax, $l) = @_;
    my($min, $max) = bounds($l);

    return($min < $bmin ? $min : $bmin,
	   $max > $bmax ? $max : $bmax);
}

1;

