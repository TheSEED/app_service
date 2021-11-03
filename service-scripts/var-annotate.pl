#! /usr/bin/env perl

use strict;
use Carp;
use Data::Dumper;
use File::Basename;
use Getopt::Long;
use Storable qw(nstore retrieve);
use lib dirname (__FILE__);
use DT;

my $usage = "Usage: $0 ref.fa ref.gff 1.vcf [2.vcf ...] > var.table\n\n";

my ($help, $min_alt_depth, $min_alt_fract, $min_map_quality, $show_header, $show_html);

GetOptions("h|help"     => \$help,
           "d=i"        => \$min_alt_depth,
           "f=f"        => \$min_alt_fract,
           "q=f"        => \$min_map_quality,
           "header"     => \$show_header,
           "html"       => \$show_html,
	  ) or die("Error in command line arguments\n");

$help and die $usage;

my $ref_fasta = shift @ARGV;
my $ref_gff  = shift @ARGV;
my @vcf_files = grep { -s $_ } @ARGV;

-f $ref_fasta or die "Reference fasta $ref_fasta missing\n";
-s $ref_fasta or die "Reference fasta $ref_fasta empty\n";
-f $ref_gff or die "Reference GFF $ref_gff missing\n";
-s $ref_gff or die "Reference GFF $ref_gff empty\n";

@vcf_files or die "No VCF files specified\n";

#-s $ref_fasta && -s $ref_gff && @vcf_files or die $usage;

$min_alt_depth   ||= 1;
$min_alt_fract   ||= 0;
$min_map_quality ||= 0;

my $features = get_sorted_features($ref_fasta, $ref_gff);
# nstore($features, 'features.store');
# my $features = retrieve('features.store');
# print STDERR '$features = '. Dumper($features);

my @snps;
for my $vcf (@vcf_files) {
    my $sample = $vcf; ($sample) = $sample =~ /(\w+)\/var.snpEff.raw.vcf/;
    my $sample_snps = vcf_to_snps($vcf, $sample);
    @snps = (@snps, @$sample_snps);
    # print STDERR '$snps = '. Dumper($snps);
}

my @head = ('Sample', 'Contig', 'Pos', 'Ref', 'Var', 'Score', 'Var cov', 'Var frac',
            'Type', 'Ref nt', 'Var nt', 'Ref nt pos change', 'Ref aa pos change', 'Frameshift',
            'Gene ID', 'Locus tag', 'Gene name', 'Function',
            "Upstream feature",
            "Downstream feature" );

if ($show_html) {
    my @rows;
    for (@snps) {
        # my $known = $known_snps{"$_->[0],$_->[1]"} and next;
        my $minor = 1 if $_->[5] < 10 || $_->[6] < 5 || $_->[7] < 0.5;
        my @c = map { DT::span_css($_, 'wrap') }
                map { $minor ? DT::span_css($_, "opaque") : $_ }
                map { ref $_ eq 'ARRAY' ? $_->[0] ? linked_gene(@$_) : undef : $_ } @$_;
        push @rows, \@c;
    }
    DT::print_dynamic_table(\@head, \@rows, { title => 'SNPs', extra_css => extra_css() });
} else {
    print join("\t", map { s/\s/_/g; $_ } @head) . "\n" if $show_header;
    for (@snps) {
        # next if $known_snps{"$_->[0],$_->[1]"};
        # my @c = map { ref $_ eq 'ARRAY' ? $_->[0] ? $_->[0] : undef : $_ } @$_;
        my @c = map { ref $_ eq 'ARRAY' ? $_->[0] ? $_->[1] : undef : $_ } @$_;
        print join("\t", @c) . "\n";
    }
}

sub vcf_to_snps {
    my ($file, $sample) = @_;
    my $vars = read_var($file);
    my @snps;
    for my $var (@$vars) {
        my ($ctg, $pos, $ref, $alt, $score, $info) = @{$var}[0, 1, 3, 4, 5, 7];
        # print STDERR '$var = '. Dumper($var);
        my ($alt_dp, $alt_frac);
        if ($info->{DP4}) {
            my @dp4 = split(/,/, $info->{DP4});
            $alt_dp = $dp4[2] + $dp4[3];
            $alt_frac = sprintf("%.2f", $alt_dp / sum(@dp4));
        } elsif ($info->{AO} && $info->{DP}) {
            $alt_dp = $info->{AO};
            $alt_frac = sprintf("%.2f", $alt_dp / $info->{DP});
        }

		my @eff = split(/\|/, $info->{EFF});
		my $ref_nt_change = "";
		my $ref_aa_change = "";
		if ($eff[3] =~ /p\.(.+)\/c\.(.+)/) {
			$ref_aa_change = $1;
			$ref_nt_change = $2;
		}
        
        my $map_qual = $info->{MQ} || $info->{MQM};

        # print STDERR join("\t", $ctg, $pos, $alt_dp, $alt_frac, $map_qual) . "\n";
        next unless $alt_frac >= $min_alt_fract && $alt_dp >= $min_alt_depth && $map_qual >= $min_map_quality;

        my $type = length($alt) > length($ref) ? 'Insertion' : length($alt) < length($ref) ? 'Deletion' : undef;

        my $hash = feature_info_for_position($ctg, $pos, $features);
        # print STDERR '$hash = '. Dumper($hash);

        my ($nt1, $nt2, $aa1, $aa2);
        my ($locus, $gene_name, $func);
        my $gene = $hash->{gene};
        my $frameshift;
        if ($gene) {
            my $dna = lc $gene->[10];
            my $strand = $gene->[5];
            my $p = $hash->{pos_in_gene};
            my $win = max(length($ref), length($alt));
            # my $win = length($ref);
            my $beg = $p - 1; $beg -= (length($ref)-1) if $strand eq '-';
            my $end = $beg + $win - 1;
            while ($beg % 3) {
                $beg--;
            }
            while (($end+1) % 3) {
                $end++;
            }
            my $size = $end - $beg + 1;
            my $alt_dna = $alt; $alt_dna = rev_comp($alt_dna) if $strand eq '-';

            if ($gene->[0] =~ /peg/) {
                my $beg_delta = $strand eq '+' ? ($p-$beg-1) : ($p-$beg-length($ref));
                $nt1 = substr($dna, $beg, $size);
                $nt2 = $nt1; substr($nt2, $beg_delta, length($ref)) = $alt_dna;
                $aa1 = translate($nt1, undef, 0);
                $aa2 = translate($nt2, undef, 0);
                if (length($alt) == length($ref)) {
                    $type = $aa1 eq $aa2 ? 'Synon' : 'Nonsyn';
                } else {
                    $frameshift = 'yes' if (length($alt) - length($ref)) % 3;
                }
            }
            # print STDERR '$gene = '. Dumper($gene);

            $locus = $gene->[9]->{LocusTag};
            # $locus = $locus->[0] if $locus;
            $locus =~ s/\S+://;
            # $gene_name = $gene->[9]->{GENE}->[0];
            $gene_name = $gene->[9]->{GENE};
            $gene_name =~ s/\S+://;

            $func = $gene->[8];
            # $func ||= 'hypothetical protein' if $gene->[0];
            # $func = "$gene_name, $func" if $gene_name;
        }

        push @snps, [ $sample, $ctg, $pos, $ref, $alt, $score, $alt_dp, $alt_frac,
                      $type, $nt1, $nt2, $ref_nt_change, $ref_aa_change, $frameshift,
                      $gene->[0], $locus, $gene_name, [ $gene->[0], $func ],
                      [ @{$hash->{left}}[0, 8] ],
                      [ @{$hash->{right}}[0, 8] ]
                    ];

    }
    wantarray ? @snps : \@snps;
}

sub extra_css {
    return <<End_of_CSS;
<style type="text/css">
  .opaque {
      opacity:0.50;
  }
  .highlight {
    text-decoration:underline;
  }
</style>
End_of_CSS
}

sub add_link {
    my ($url, $txt) = @_;
    $txt ||= $url;
    return "<a href=$url>$txt</a>";
}

sub linked_gene {
    my ($url, $txt) = @_;
    $txt ||= $url;
    return $txt;
}

sub read_var {
    my ($file) = @_;
    my @vars = map  { my $hash = { map { my ($k, $v) = split /=/; $v ||= 1; $k => $v } split(/;/, $_->[7]) }; $_->[7] = $hash; $_ }
               map  { [split /\t/] }
               map  { chomp; $_ }
               grep { !/^#/ } $file ? `cat $file` : <STDIN>;
    wantarray ? @vars : \@vars;
}

sub get_sorted_features {
    my ($ref_fasta, $ref_gff) = @_;
    my @seqs = read_fasta($ref_fasta);
    my %seqH = map { $_->[0] => $_->[2] } @seqs;
    my $gff = read_gff_tree($ref_gff);

    my %features;

    # assume gff is sorted
    for (@$gff) {
        my $contig = $_->{contig};
        my $start  = $_->{start};
        my $end    = $_->{end};
        my $strand = $_->{strand};
        my $length = $_->{length};
        my $func   = $_->{attribute}->{Name} || $_->{attribute}->{product};
        my $locus  = $_->{attribute}->{locus_tag};
        my $alias  = { LocusTag => $locus, GENE => $_->{attribute}->{gene} };
        my $desc   = $_->{descendants}->[0];
        $func      = $desc->{attribute}->{product} if $desc;
        my $note   = $desc->{attribute}->{Note} if $desc;
        $note    ||= $_->{attribute}->{Name};

        my $dna = uc substr($seqH{$contig}, $start-1, $length);
        $dna = rev_comp($dna) if $strand eq '-';

        my $feature = [ $_->{id},
                        '',
                        $contig,
                        $start,
                        $end,
                        $strand,
                        $length,
                        $note,  # originally location
                        $func,
                        $alias,
                        $dna ];

        push @{$features{$contig}}, $feature;
    }

    # my $features = $sap->all_features( -ids => [$gid] )->{$gid};
    # my $locH     = $sap->fid_locations( -ids => $features, -boundaries => 1 );
    # my $funcH    = $sap->ids_to_functions( -ids => $features );
    # # my $dnaH     = $sap->ids_to_sequences( -ids => $features );
    # my $dnaH     = $sap->locs_to_dna( -locations => $locH );
    # my $aliasH   = $sap->fids_to_ids( -ids => $features ); # LocusTag, NCBI, RefSeq, GeneID, GENE, Miscellaneous lists
    # my @sorted   = sort { $a->[1] cmp $b->[1] || $a->[2] cmp $b->[2] ||
    #                       $a->[3] <=> $b->[3] || $a->[4] <=> $b->[4] }
    #                map  { my $loc = $locH->{$_};
    #                       my ($contig, $beg, $end, $strand) = SeedUtils::parse_location($loc);
    #                       my ($org, $ctg) = split(/:/, $contig);
    #                       my $lo = $beg <= $end ? $beg : $end;
    #                       my $hi = $beg <= $end ? $end : $beg;
    #                       my $len = $hi - $lo + 1;
    #                       [ $_, $org, $ctg, $lo, $hi, $strand, $len, $loc, $funcH->{$_}, $aliasH->{$_}, uc $dnaH->{$_} ]
    #                     } @$features;
    # for (@sorted) {
    #     my $ctg = $_->[2];
    #     push @{$features{$ctg}}, $_;
    # }

    wantarray ? %features : \%features;
}

sub feature_info_for_position {
    my ($ctg, $pos, $features) = @_;

    my ($left, $right, @cover);

    my $index = binary_search_in_sorted_features($ctg, $pos, $features);

    $left = $features->{$ctg}->[$index] if defined($index) && $index >= 0;

    my @cover;
    for (my $i = $index + 1; $features->{$ctg} && $i < @{$features->{$ctg}}; $i++) {
        my $fea = $features->{$ctg}->[$i];
        my ($lo, $hi) = @{$fea}[3, 4];
        my $overlap = $lo <= $pos && $pos <= $hi;
        if (! $overlap) { $right = $fea; last; }
        push @cover, $fea;
    }

    my @overlapping_genes = sort { $b->[6] <=> $a->[6] } @cover; # sort genes by length
    # my @overlapping_other = grep { $_->[0] !~ /peg/ } @cover;
    my @overlapping_other;

    my (%func_seen, %func_cnt, %func_lo, %func_hi);
    for (@overlapping_genes) {
        my $len  = $_->[6];
        my $func = $_->[8];
        my $lo   = $_->[3];
        my $hi   = $_->[4];
        if (!hypo_or_mobile($func)) {
            $func_cnt{$func}++;
            $func_lo{$func} = $lo if $lo < $func_lo{$func} || ! defined($func_lo{$func});
            $func_hi{$func} = $hi if $hi > $func_hi{$func};
        }
    }
    for (($left, $right)) {
        my $func = $_->[8];
        my $lo   = $_->[3];
        my $hi   = $_->[4];
        if ($func_cnt{$func}) {
            $func_cnt{$func}++;
            $func_lo{$func} = $lo if $lo < $func_lo{$func} || ! defined($func_lo{$func});
            $func_hi{$func} = $hi if $hi > $func_hi{$func};
        }
    }
    for my $func (keys %func_cnt) {
        my $len = $func_hi{$func} - $func_lo{$func} + 1;
    }

    my ($gene) = @overlapping_genes;
    my $pos_in_gene;
    if ($gene) {
        my ($lo, $hi, $strand) = @{$gene}[3, 4, 5];
        $pos_in_gene =  $strand eq '+' ? $pos - $lo + 1 : $hi - $pos + 1;
    }

    my %hash;

    $hash{overlapping_genes} = \@overlapping_genes if @overlapping_genes;
    $hash{overlapping_other} = \@overlapping_other if @overlapping_other;
    $hash{gene}              = $gene               if $gene;
    $hash{pos_in_gene}       = $pos_in_gene        if $pos_in_gene;
    $hash{left}              = $left               if $left;
    $hash{right}             = $right              if $right;

    wantarray ? %hash : \%hash;
}

# Assumes the features are in ascending order on left coordinate and then right coordinate.
# Find the index of the rightmost feature who does not have a right neighbor that is to the left of the position
# Return -1 if no such feature can be found.

sub binary_search_in_sorted_features {
    my ($ctg, $pos, $features, $x, $y) = @_;

    return    if !$features || !$features->{$ctg};
    return -1 if $features->{$ctg}->[0]->[4] >= $pos;

    my $feas = $features->{$ctg};
    my $n = @$feas;

    $x = 0      unless defined $x;
    $y = $n - 1 unless defined $y;

    while ($x < $y) {
        my $m = int(($x + $y) / 2);

        # Terminate if:
        #   (1) features[m] is to the left pos, and
        #   (2) features[m+1] covers or is to the right of pos

        my $m2 = $feas->[$m]->[4];
        my $n2 = $feas->[$m+1]->[4];

        return $m if $m2 < $pos && ($n2 >= $pos || !defined($n2));

        if ($m2 < $pos) { $x = $m + 1 } else { $y = $m }
    }

    return $x;
}

sub hypo_or_mobile {
    my ($func) = @_;
    return 0;
    # return !$func || SeedUtils::hypo($func) || $func =~ /mobile/i;
}

sub read_gff_tree {
    my ($file) = @_;
    my $header = `cat $file | grep "^#"`;
    my @lines = `cat $file | grep -v "^#"`;
    # my @lines = `cat $file | grep -v "^#" |head`;
    my %id_to_index;
    my %rootH;
    my @features;
    my $index;
    shift @lines if $lines[0] =~ /region/;
    for (@lines) {
        chomp;
        my ($contig, $source, $feature, $start, $end, $score, $strand, $fname, $attribute) = split /\t/;
        my %hash = map { my ($k,$v) = split /=/; $k => $v } split(/;\s*/, $attribute);
        my $id = $hash{ID};
        my $ent = { id => $id,
                    contig => $contig,
                    source => $source,
                    feature => $feature,
                    start => $start,
                    end => $end,
                    length => $end - $start + 1,
                    score => $end,
                    strand => $strand,
                    fname => $fname,
                    attribute => \%hash };
        my $parent = $hash{Parent};
        if (!$parent) {
            push @features, $ent;
            $id_to_index{$id} = $index++;
            next;
        }
        while ($parent) {
            $rootH{$id} = $parent;
            $parent = $rootH{$parent};
        }
        my $root_index = $id_to_index{$rootH{$id}};
        push @{$features[$root_index]->{descendants}}, $ent;
    }
    return \@features;
}

sub read_fasta
{
    my $dataR = ( $_[0] && ref $_[0] eq 'SCALAR' ) ?  $_[0] : slurp( @_ );
    $dataR && $$dataR or return wantarray ? () : [];

    my $is_fasta = $$dataR =~ m/^[\s\r]*>/;
    my @seqs = map { $_->[2] =~ tr/ \n\r\t//d; $_ }
               map { /^(\S+)([ \t]+([^\n\r]+)?)?[\n\r]+(.*)$/s ? [ $1, $3 || '', $4 || '' ] : () }
               split /[\n\r]+>[ \t]*/m, $$dataR;

    #  Fix the first sequence, if necessary
    if ( @seqs )
    {
        if ( $is_fasta )
        {
            $seqs[0]->[0] =~ s/^>//;  # remove > if present
        }
        elsif ( @seqs == 1 )
        {
            $seqs[0]->[1] =~ s/\s+//g;
            @{ $seqs[0] } = ( 'raw_seq', '', join( '', @{$seqs[0]} ) );
        }
        else  #  First sequence is not fasta, but others are!  Throw it away.
        {
            shift @seqs;
        }
    }

    wantarray() ? @seqs : \@seqs;
}

sub slurp
{
    my ( $fh, $close );
    if ( $_[0] && ref $_[0] eq 'GLOB' )
    {
        $fh = shift;
    }
    elsif ( $_[0] && ! ref $_[0] )
    {
        my $file = shift;
        if    ( -f $file                       ) { }
        elsif (    $file =~ /^<(.*)$/ && -f $1 ) { $file = $1 }  # Explicit read
        else                                     { return undef }
        open( $fh, '<', $file ) or return undef;
        $close = 1;
    }
    else
    {
        $fh = \*STDIN;
        $close = 0;
    }

    my $out = '';
    my $inc = 1048576;
    my $end =       0;
    my $read;
    while ( $read = read( $fh, $out, $inc, $end ) ) { $end += $read }
    close( $fh ) if $close;

    \$out;
}

sub write_fasta
{
    my ( $fh, $close, $unused ) = output_filehandle( shift );
    ( unshift @_, $unused ) if $unused;

    ( ref( $_[0] ) eq "ARRAY" ) or confess "Bad sequence entry passed to print_alignment_as_fasta\n";

    #  Expand the sequence entry list if necessary:

    if ( ref( $_[0]->[0] ) eq "ARRAY" ) { @_ = @{ $_[0] } }

    foreach my $seq_ptr ( @_ ) { print_seq_as_fasta( $fh, @$seq_ptr ) }

    close( $fh ) if $close;
}

sub output_filehandle
{
    my $file = shift;

    #  Null string or undef

    return ( \*STDOUT, 0 ) if ( ! defined( $file ) || ( $file eq "" ) );

    #  FILEHANDLE

    return ( $file, 0 ) if ( ref( $file ) eq "GLOB" );

    #  Some other kind of reference; return the unused value

    return ( \*STDOUT, 0, $file ) if ref( $file );

    #  File name

    my $fh;
    open( $fh, '>', $file ) || die "Could not open output $file\n";
    return ( $fh, 1 );
}

sub print_seq_as_fasta
{
    my $fh = ( ref $_[0] eq 'GLOB' ) ? shift : \*STDOUT;
    return if ( @_ < 2 ) || ( @_ > 3 ) || ! ( defined $_[0] && defined $_[-1] );
    #  Print header line
    print $fh  ( @_ == 3 && defined $_[1] && $_[1] =~ /\S/ ) ? ">$_[0] $_[1]\n" : ">$_[0]\n";
    #  Print sequence, 60 chars per line
    print $fh  join( "\n", $_[-1] =~ m/.{1,60}/g ), "\n";
}

sub rev_comp {
    my ($dna) = @_;
    $dna = reverse($dna);
    $dna =~ tr/acgtumrwsykbdhvACGTUMRWSYKBDHV/tgcaakywsrmvhdbTGCAAKYWSRMVHDB/;
    return $dna;
}

sub translate {
    my( $dna,$code,$start ) = @_;
    my( $i,$j,$ln );
    my( $x,$y );
    my( $prot );

    if (! defined($code)) {
        $code = &standard_genetic_code;
    }
    $ln = length($dna);
    $prot = "X" x ($ln/3);
    $dna =~ tr/a-z/A-Z/;

    for ($i=0,$j=0; ($i < ($ln-2)); $i += 3,$j++) {
        $x = substr($dna,$i,3);
        if ($y = $code->{$x}) {
            substr($prot,$j,1) = $y;
        }
    }

    if (($start) && ($ln >= 3) && (substr($dna,0,3) =~ /^[GT]TG$/)) {
        substr($prot,0,1) = 'M';
    }
    return $prot;
}

sub standard_genetic_code {
    my $code = {};
    $code->{"AAA"} = "K";
    $code->{"AAC"} = "N";
    $code->{"AAG"} = "K";
    $code->{"AAT"} = "N";
    $code->{"ACA"} = "T";
    $code->{"ACC"} = "T";
    $code->{"ACG"} = "T";
    $code->{"ACT"} = "T";
    $code->{"AGA"} = "R";
    $code->{"AGC"} = "S";
    $code->{"AGG"} = "R";
    $code->{"AGT"} = "S";
    $code->{"ATA"} = "I";
    $code->{"ATC"} = "I";
    $code->{"ATG"} = "M";
    $code->{"ATT"} = "I";
    $code->{"CAA"} = "Q";
    $code->{"CAC"} = "H";
    $code->{"CAG"} = "Q";
    $code->{"CAT"} = "H";
    $code->{"CCA"} = "P";
    $code->{"CCC"} = "P";
    $code->{"CCG"} = "P";
    $code->{"CCT"} = "P";
    $code->{"CGA"} = "R";
    $code->{"CGC"} = "R";
    $code->{"CGG"} = "R";
    $code->{"CGT"} = "R";
    $code->{"CTA"} = "L";
    $code->{"CTC"} = "L";
    $code->{"CTG"} = "L";
    $code->{"CTT"} = "L";
    $code->{"GAA"} = "E";
    $code->{"GAC"} = "D";
    $code->{"GAG"} = "E";
    $code->{"GAT"} = "D";
    $code->{"GCA"} = "A";
    $code->{"GCC"} = "A";
    $code->{"GCG"} = "A";
    $code->{"GCT"} = "A";
    $code->{"GGA"} = "G";
    $code->{"GGC"} = "G";
    $code->{"GGG"} = "G";
    $code->{"GGT"} = "G";
    $code->{"GTA"} = "V";
    $code->{"GTC"} = "V";
    $code->{"GTG"} = "V";
    $code->{"GTT"} = "V";
    $code->{"TAA"} = "*";
    $code->{"TAC"} = "Y";
    $code->{"TAG"} = "*";
    $code->{"TAT"} = "Y";
    $code->{"TCA"} = "S";
    $code->{"TCC"} = "S";
    $code->{"TCG"} = "S";
    $code->{"TCT"} = "S";
    $code->{"TGA"} = "*";
    $code->{"TGC"} = "C";
    $code->{"TGG"} = "W";
    $code->{"TGT"} = "C";
    $code->{"TTA"} = "L";
    $code->{"TTC"} = "F";
    $code->{"TTG"} = "L";
    $code->{"TTT"} = "F";
    return $code;
}

sub max {
    my @x = @_;
    my $m = shift @x;
    for (@x) { $m = $_ if $_ > $m };
    return $m;
}

sub sum {
    my @x = @_;
    my $s;
    $s += $_ for @x;
    return $s;
}
