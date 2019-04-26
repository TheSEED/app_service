
#
# Code adapted from https://www.perlmonks.org/?node_id=308579
#
# Note that this module contains global state. Beware.
#

# Implements Ukkonen 1995
# Code is based on the description and pseudo code in
#  http://www.csse.monash.edu.au/~lloyd/tildeAlgDS/Tree/Suffix/
# However
# - our string positions are 0 based
# - We represent an edge as (first_ch, length) instead of
#   (first_ch, last_ch)
# - We always add a terminator
#
# - Nodes are hash references mapping the first char
#   of an outgoing edge to the edge itself
# - Edges are array references: [first_ch, length, target_node]
#
# To make this handle LCS, I added a bitmap representing from
# which word a suffix comes to each leaf.

package Bio::KBase::AppService::LongestCommonSubstring;

use base 'Exporter';
our @EXPORT_OK = qw(BuildString BuildTree DrawTree LongestCommonSubstring);

use strict;
use Scalar::Util qw(weaken);
no warnings 'recursion';

# use lib "/home/ton/lib";
# use Debug qw(debug);
use Data::Dumper;

# Infinity is used as edge length on leafs
use constant INFINITY => 1e5000;
# Char code of some char that won't appear in any of the strings
# Should still work if we use some very high invalid unicode value
# here, but perl 5.8.0 unicode still gets it wrong, so fall back
# to 192 for now (Restricts validity to 64 input strings)
use constant INVALID_BASE => 192;
# We (ab)use key "\xff\xff" to represent the suffix links
use constant SLINK    => "\xff\xff";

my ($s, $k, $txt, $word_nr, $word_map);

# For debugging. Nicely draw the suffix tree
sub DrawTree {
    my ($s, $prefix) = @_;
    print "->", $s->{+SLINK} ? "+" : "*";
    $prefix .= "  ";
    my @keys = sort keys %$s;
    pop @keys if $keys[-1] eq SLINK;
    for (0..$#keys) {
        print "$prefix|\n$prefix+" if $_;
        my ($k1, $l1, $s1) = @{$s->{$keys[$_]}};
        if ($l1 == INFINITY) {
            my $str = substr($txt, $k1);
            #$str =~ s/[^\x00-\x7f]/:/g;
            # printf "--%s(%2d)\$\n", $str, $k1;
            print "--$str\$\n";
        } else {
            #printf "--%s(%2d)", substr($txt, $k1, $l1), $k1;
            #DrawTree($s1, $prefix . ($_ == $#keys ? " " : "|") . " " x(6+$l1));
            my $str = substr($txt, $k1, $l1);
            #$str =~ s/[^\x00-\x7f]/:/g;
            printf "--$str";
            DrawTree($s1,$prefix . ($_ == $#keys ? " " : "|") . " "   x(2+$l1));
        }
    }
}

sub Update {
    my $i = shift;
    # (s, (k, i-1)) is the canonical reference pair for the active point
    my $old_root;
    my $chr = substr($txt, $i, 1);
    while (my $r = TestAndSplit($i-$k, $chr)) {
        $r->{$chr} = [$i, INFINITY, $word_map];
        # build suffix-link active-path
        weaken($old_root->{+SLINK} = $r) if $old_root;
        $old_root = $r;
        $s = $s->{+SLINK};
        Canonize($i-$k);
    }
    if (ord($chr) >= INVALID_BASE) {
        vec($word_map,   $word_nr, 1) = 0;
        vec($word_map, ++$word_nr, 1) = 1;
    }
    weaken($old_root->{+SLINK} = $s) if $old_root;
}

sub TestAndSplit {
    my ($l, $t) = @_;
    return !$s->{$t} && $s unless $l;
    my ($k1, $l1, $s1)  = @{$s->{substr($txt, $k, 1)}};
    my $try = substr($txt, $k1 + $l, 1);
    return if $t eq $try;
    # s---->r---->s1
    my %r = ($try => [$k1 +$l, $l1-$l, $s1]);
    $s->{substr($txt, $k1, 1)} = [$k1, $l, \%r];
    return \%r;
}

sub Canonize {
    # s--->...
    my $l = shift || return;

    # find the t_k transition g'(s,(k1,l1))=s' from s
    my ($l1, $s1) = @{$s->{substr($txt, $k, 1)}}[1,2];
    # s--(k1,l1)-->s1
    while ($l1 <= $l) {
        # s--(k1,l1)-->s1--->...
        $k += $l1;  # remove |(k1,l1)| chars from front of (k,l)
        $l -= $l1;
        $s  = $s1;
        # s--(k1,l1)-->s1
        ($l1, $s1) = @{$s->{substr($txt, $k, 1)}}[1,2] if $l;
    }
}

# construct suffix tree for $txt[0..N-1]
sub BuildTree {
    # bottom or _|_
    my %bottom;
    my %root = (SLINK() => \%bottom);
    $s = \%root;

    # Create edges for all chars from bottom to root
    my $end_char = length($txt)-1;
    $bottom{substr($txt, $_, 1)} ||= [$_, 1, \%root] for 0..$end_char;

    $k = 0;
    vec($word_map = "", $word_nr = 0, 1) = 1;

    for (0..$end_char) {
        # follow path from active-point
        Update($_);
        Canonize($_-$k+1);
    }
    # Get rid of bottom link
    delete $root{+SLINK};
    return \%root;
}

my ($best, $to, $want_map);
sub Lcs {
    my ($s, $depth) = @_;
    # Skip leafs
    return $s if !ref($s);
    my $word_map = "";
    for (keys %$s) {
        next if $_ eq SLINK;
        my ($l, $node) = @{$s->{$_}}[1,2];
        $word_map |= Lcs($node, $depth+$l);
    }
    return $word_map if $word_map ne $want_map || $best >= $depth;
    # You may already be a winner !
    # Only do the hard work if we can gain.
    $best = $depth;
    for (keys %$s) {
        next if $_ eq SLINK;
        $to = $s->{$_}[0];
        last;
    }
    return $word_map;
}

sub LongestCommonSubstring {
    my $tree = shift;
    $best = 0;
    $to   = 0;
    Lcs($tree, 0);
    return substr($txt, $to-$best, $best);
}

sub BuildString {
    die "Want at least two strings" if @_ < 2;
#    die "Can't currently handle more this many strings" if
#        @_ >= 256-INVALID_BASE();
    $txt = "";
    my $chr = INVALID_BASE;
    $want_map = "";
    my $i;
    for (@_) {
        $txt .= $_;
        $txt .= chr($chr++);
        vec($want_map, $i++, 1) = 1;
    }
}

sub CommonSubstring {
    BuildString(@_);
    return LongestCommonSubstring(BuildTree);
}

# debug(qw[Update TestAndSplit Canonize(d)]);

1;
