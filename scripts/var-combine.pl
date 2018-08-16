#! /usr/bin/env perl

use strict;
use Data::Dumper;
use File::Basename;
use Getopt::Long;
use lib dirname (__FILE__);
use DT;

my $usage = "Usage: $0 concat.var.list\n\n";

my ($help, $show_header, $show_html);

GetOptions("h|help"     => \$help,
           "header"     => \$show_header,
           "html"       => \$show_html,
	  ) or die("Error in command line arguments\n");

my $var_list_file = shift @ARGV;
my @lines = $var_list_file ? `cat $var_list_file` : <STDIN>;

my @head = ('Samples', 'Contig', 'Pos', 'Ref', 'Var', 'Score', 'Var cov', 'Var frac',
            'Type', 'Ref nt', 'Var nt', 'Ref aa', 'Var aa', 'Frameshift',
            'Gene ID', 'Locus tag', 'Gene name', 'Function',
            "Upstream feature",
            "Downstream feature" );

if ($lines[0] =~ /^Sample/) {
    my $line = $lines[0];
    chomp($line);
    @head = split(/\t/, $line); $head[0] = 'Samples';
}

my @vars;
for (@lines) {
    next if /^(#|Sample)/;
    chomp;
    my @cols = split/\t/;
    push @cols, undef while @cols < @head;
    push @vars, \@cols;
}

my %groups;

for (@vars) {
    my ($sample, $contig, $pos) = @$_;
    my $var_key = join(":", $contig, $pos);
    push @{$groups{$var_key}}, $_;
}

# print STDERR '\%groups = '. Dumper(\%groups);

my @snps;
for my $k (sort keys %groups) {
    my $var = $groups{$k}->[0];
    $var->[0] = scalar@{$groups{$k}}.":".join(",", map { $_->[0] } @{$groups{$k}});
    $var->[6] = sprintf("%.1f", mean(map { $_->[6] } @{$groups{$k}}));
    $var->[7] = sprintf("%.2f", mean(map { $_->[7] } @{$groups{$k}}));
    push @snps, $var;
}

# print STDERR '\@vars = '. Dumper(\@vars);

if ($show_html) {
    my @rows;
    for (@snps) {
    	$_->[14] = '<a href="/view/Feature/' . $_->[14] . '" target="_blank">' . $_->[14] . '</a>';
        my $minor = 1 if $_->[5] < 10 || $_->[6] < 5 || $_->[7] < 0.5;
        my @c = map { DT::span_css($_, 'wrap') }
                map { $minor ? DT::span_css($_, "opaque") : $_ }
                map { ref $_ eq 'ARRAY' ? $_->[0] ? linked_gene(@$_) : undef : $_ } @$_;
        push @rows, \@c;
    }
    DT::print_dynamic_table(\@head, \@rows, { title => 'Annotated Variants', extra_css => extra_css() });
} else {
    print join("\t", map { s/\s/_/g; $_ } @head) . "\n" if $show_header;
    for (@snps) {
        my @c = map { ref $_ eq 'ARRAY' ? $_->[0] ? $_->[1] : undef : $_ } @$_;
        print join("\t", @c) . "\n";
    }
}

sub linked_gene {
    my ($url, $txt) = @_;
    $txt ||= $url;
    return $txt;
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

sub mean {
    my @x = @_;
    my $n = @x;
    my $s;
    $s += $_ for @x;
    return $s/$n;
}
