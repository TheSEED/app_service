#! /usr/bin/env perl

# requires: samtools v1.3

use strict;
use Carp;
use Cwd 'abs_path';
use Data::Dumper;
use File::Basename;
use File::Which;
use Getopt::Long;

my $usage = <<"End_of_Usage";

usage: $0 [options] ref.fq reads_1.fq [reads_2.fq]

       -a algo          - alignment algorithm [bwa_mem bwa_mem_strict bowtie2 mosaik last] (D = bwa_mem)
       -o dir           - output directory (D = ref_reads_[algo])
       -t int           - number of threads (D = 8)
       -m size          - max memory per thread; suffix K/M/G recognized (D = 2G)
       --vc tool        - variant calling [samtools freebayes] (D = freebayes)

End_of_Usage

my ($help, $algo, $memory, $nthread, $outdir, $paired, $vc);

GetOptions("h|help"        => \$help,
           "a|algo=s"      => \$algo,
           "m|memory=s"    => \$memory,
           "o|outdir=s"    => \$outdir,
           "p|paired"      => \$paired,
           "t|threads=i"   => \$nthread,
           "vc=s"          => \$vc);

my $ref   = shift @ARGV;
my $read1 = shift @ARGV;
my $read2 = shift @ARGV;

$ref && $read1 or die $usage;

$ref   = abs_path($ref);
$read1 = abs_path($read1);
$read2 = abs_path($read2) if $read2;
$read2 = other_read_file_in_pair($read1) if $paired;

$nthread ||= 8;
$memory  ||= '2G'; $memory .= 'G' if $memory =~ /\d$/;
$algo    ||= 'bwa_mem'; $algo .= "_se" if !$read2;
$algo      =~ s/-/_/g; $algo = lc $algo;
$vc      ||= 'freebayes'; $vc = lc $vc;
$outdir  ||= generate_dir_name($algo, $ref, $read1);

print "READS = $read1 $read2\n";
print "ALGO = $algo\n";

if (eval "defined(&map_with_$algo)") {
    print "> $outdir\n";
    run("mkdir -p $outdir");
    chdir($outdir);
    eval "&map_with_$algo";
    if ($@) {
        print $@;
    } else {
        compute_stats();
        if ($vc && eval "defined(&call_variant_with_$vc)") {
            eval "&call_variant_with_$vc";
            print $@ if $@;
            compute_consensus() unless $@;
        }
        summarize() unless -s "summary.txt";
    }
} else {
    die "Mapping algorithm not defined: $algo\n";
}

sub generate_dir_name {
    my ($algo, $ref, $reads) = @_;
    $ref   =~ s|.*/||; $ref   =~ s/\.(fasta|fna|fa)//;
    $reads =~ s|.*/||; $reads =~ s/\.(fastq|fq).*//; $reads =~ s/_(1|2)//;
    return "$ref\_$reads\_$algo";
}

sub other_read_file_in_pair {
    my ($r1) = @_;
    my $r2 = $r1;
    $r2 =~ s/R1\./R2\./;
    return $r2 if -s $r2 && $r2 ne $r1;
}

sub call_variant_with_samtools {
    verify_cmd(qw(samtools bcftools));
    -s "mpileup"        or run("samtools mpileup -6 -uf ref.fa aln.bam > mpileup");
    -s "var.sam.vcf"    or run("bcftools call -vc mpileup > var.sam.vcf");
    -s "var.sam.q.vcf"  or run("vcffilter -f 'QUAL > 10 & DP > 5' var.sam.vcf > var.sam.q.vcf");
    -s "var.sam.count"  or run("grep -v '^#' var.sam.vcf |cut -f4 |grep -v 'N' |wc -l > var.sam.count");
    -s "var.vcf"        or run("ln -s -f var.sam.q.vcf var.vcf");
}

sub call_variant_with_freebayes {
    verify_cmd(qw(freebayes-parallel fasta_generate_regions.py vcffilter vcffirstheader vcfuniq vcfstreamsort));
    -s "var.fb.vcf"     or run("bash -c 'freebayes-parallel <(fasta_generate_regions.py ref.fa.fai 100000) $nthread -p 1 -f ref.fa aln.bam >var.fb.vcf'");
    -s "var.fb.q10.vcf" or run("vcffilter -f 'QUAL > 10 & DP > 5' var.fb.vcf > var.fb.q10.vcf");
    -s "var.fb.q1.vcf"  or run("vcffilter -f 'QUAL > 1' var.fb.vcf > var.fb.q1.vcf");
    -s "var.fb.count"   or run("grep -v '^#' var.fb.vcf |cut -f4 |grep -v 'N' |wc -l > var.fb.count");
    -s "var.vcf"        or run("ln -s -f var.fb.q10.vcf var.vcf");
}

sub compute_consensus {
    verify_cmd(qw(bgzip tabix bcftools));
    -s "var.vcf.gz"     or run("bgzip -c var.vcf > var.vcf.gz");
    -s "var.vcf.gz.tbi" or run("tabix var.vcf.gz");
    -s "consensus"      or run("bcftools consensus -c chain -f ref.fa var.vcf.gz >consensus");
}

sub compute_stats {
    verify_cmd(qw(samtools bedtools));
    -s "ref.fa.fai"     or run("samtools faidx ref.fa");
    -s "raw.flagstat"   or run("samtools flagstat aln.raw.sam > raw.flagstat");
    -s "flagstat"       or run("samtools flagstat aln.bam > flagstat");
    -s "stats"          or run("samtools stats aln.bam -c 1,8000,1 > stats");
  # -s "depth"          or run("samtools depth aln.bam > depth");
    -s "depth"          or run("bedtools genomecov -ibam aln.bam -d > depth");
    -s "depth.hist"     or run("bedtools genomecov -ibam aln.bam > depth.hist");
    -s "uncov.10"       or run("bedtools genomecov -ibam aln.bam -bga | perl -ne 'chomp; \@c=split/\t/; \$ln=\$c[2]-\$c[1]; print join(\"\\t\", \@c, \$ln).\"\\n\" if \$c[3]<10;' > uncov.10" );
    # BED start position 0-based and the end position 1-based (Example: NC_000962,1987085,1987701,0,616; the 0 coverage base really starts at 1987086)
}

sub map_with_bwa_mem {
    verify_cmd(qw(bwa samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read_1.fq");
    -s "read_2.fq"      or run("ln -s -f $read2 read_2.fq");
    -s "ref.fa.bwt"     or run("bwa index ref.fa");
    -s "aln-pe.sam"     or run("bwa mem -t $nthread ref.fa read_1.fq read_2.fq > aln-pe.sam 2>mem.log");
    -s "aln.raw.sam"    or run("ln -s -f aln-pe.sam aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -f 0x2 -bS aln.raw.sam > aln.keep.bam"); # keep only properly paired reads
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
  # -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread aln.keep.bam aln.sorted"); # v1.1
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
  # -s "aln.bam"        or run("ln -s -f aln.sorted.bam aln.bam");
  # -s "aln.bam.bai"    or run("samtools index aln.bam"); # v1.1
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_bwa_mem_se {
    verify_cmd(qw(bwa samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read.fq"        or run("ln -s -f $read1 read.fq");
    -s "ref.fa.bwt"     or run("bwa index ref.fa");
    -s "aln-se.sam"     or run("bwa mem -t $nthread ref.fa read.fq > aln-se.sam 2>mem.log");
    -s "aln.raw.sam"    or run("ln -s -f aln-se.sam aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -bS aln.raw.sam > aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_bwa_mem_strict {
    verify_cmd(qw(bwa samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read_1.fq");
    -s "read_2.fq"      or run("ln -s -f $read2 read_2.fq");
    -s "ref.fa.bwt"     or run("bwa index ref.fa");
    -s "aln-pe.sam"     or run("bwa mem -B9 -O16 -E1 -L5 -t $nthread ref.fa read_1.fq read_2.fq > aln-pe.sam 2>mem.log");
    -s "aln.raw.sam"    or run("ln -s -f aln-pe.sam aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -f 0x2 -q 10 -bS aln.raw.sam > aln.keep.bam"); # keep only properly paired reads
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_bwa_mem_strict_se {
    verify_cmd(qw(bwa samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read.fq"        or run("ln -s -f $read1 read.fq");
    -s "ref.fa.bwt"     or run("bwa index ref.fa");
    -s "aln-se.sam"     or run("bwa mem -B9 -O16 -E1 -L5 -t $nthread ref.fa read.fq > aln-se.sam 2>mem.log");
    -s "aln.raw.sam"    or run("ln -s -f aln-se.sam aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -bS -q 10 aln.raw.sam > aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_bowtie2 {
    verify_cmd(qw(bowtie2-build bowtie2 samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read_1.fq");
    -s "read_2.fq"      or run("ln -s -f $read2 read_2.fq");
    -s "ref.1.bt2"      or run("bowtie2-build ref.fa ref");
    -s "aln.raw.sam"    or run("bowtie2 -p $nthread -x ref -1 $read1 -2 $read2 -S aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -f 0x2 -q 10 -bS aln.raw.sam > aln.keep.bam"); # keep only properly paired reads
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_bowtie2_se {
    verify_cmd(qw(bowtie2-build bowtie2 samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read.fq"        or run("ln -s -f $read1 read.fq");
    -s "ref.1.bt2"      or run("bowtie2-build ref.fa ref");
    -s "aln.raw.sam"    or run("bowtie2 -p $nthread -x ref -U $read1 -S aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -bS -q 10 aln.raw.sam > aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_mosaik {
    # https://github.com/wanpinglee/MOSAIK/wiki/QuickStart
    verify_cmd(qw(MosaikBuild MosaikAligner samtools));
    my $bin_dir = dirname(which('MosaikAligner'));
    verify_file("$bin_dir/2.1.78.se.ann", "$bin_dir/2.1.78.pe.ann");
    -s "se.ann"         or run("ln -s -f $bin_dir/2.1.78.se.ann se.ann");
    -s "pe.ann"         or run("ln -s -f $bin_dir/2.1.78.pe.ann pe.ann");
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read_1.fq");
    -s "read_2.fq"      or run("ln -s -f $read2 read_2.fq");
    -s "ref.dat"        or run("MosaikBuild -fr ref.fa -oa ref.dat");
    -s "reads.mkb"      or run("MosaikBuild -q read_1.fq -q2 read_2.fq -out reads.mkb -st illumina -mfl 500");
    system("ls -l reads.mkb");
    sleep 5;
    system("ls -l reads.mkb");
    -s "reads.mka.bam"  or run("MosaikAligner -in reads.mkb -out reads.mka -ia ref.dat -p $nthread -annpe pe.ann -annse se.ann");
    -s "aln.raw.sam"    or run("ln -s -f reads.mka.bam aln.raw.sam");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -f 0x2 -bS reads.mka.bam > aln.keep.bam"); # keep only properly paired reads
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS reads.mka.bam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_mosaik_se {
    verify_cmd(qw(MosaikBuild MosaikAligner samtools));
    my $bin_dir = dirname(which('MosaikAligner'));
    verify_file("$bin_dir/2.1.78.se.ann", "$bin_dir/2.1.78.pe.ann");
    -s "se.ann"         or run("ln -s -f $bin_dir/2.1.78.se.ann se.ann");
    -s "pe.ann"         or run("ln -s -f $bin_dir/2.1.78.pe.ann pe.ann");
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read.fq"        or run("ln -s -f $read1 read.fq");
    -s "ref.dat"        or run("MosaikBuild -fr ref.fa -oa ref.dat");
    -s "reads.mkb"      or run("MosaikBuild -q read.fq -out reads.mkb -st illumina");
    -s "reads.mka.bam"  or run("MosaikAligner -in reads.mkb -out reads.mka -ia ref.dat -p $nthread -annpe pe.ann -annse se.ann");
    -s "aln.raw.sam"    or run("ln -s -f reads.mka.bam aln.raw.sam");
    -s "aln.keep.bam"   or run("ln -s -f reads.mka.bam aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS reads.mka.bam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_last {
    verify_cmd(qw(lastdb lastal parallel-fastq last-pair-probs maf-convert samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read_1.fq");
    -s "read_2.fq"      or run("ln -s -f $read2 read_2.fq");
    -s "index.suf"      or run("lastdb -m1111110 index ref.fa");
    -s "out1.maf"       or run("parallel-fastq -j $nthread -k 'lastal -Q1 -d108 -e120 -i1 index' < read_1.fq > out1.maf");
    -s "out2.maf"       or run("parallel-fastq -j $nthread -k 'lastal -Q1 -d108 -e120 -i1 index' < read_2.fq > out2.maf");
  # -s "out1.maf"       or run("lastal -Q1 -d108 -e120 -i1 index read_1.fq > out1.maf"); # sequential
  # -s "out2.maf"       or run("lastal -Q1 -d108 -e120 -i1 index read_2.fq > out2.maf"); # sequential
    -s "aln-pe.maf"     or run("last-pair-probs -m 0.1 out1.maf out2.maf > aln-pe.maf");
    -s "ref.fa.fai"     or run("samtools faidx ref.fa");
    -s "sam.header"     or run("awk '{ print \"\@SQ\\tSN:\"\$1\"\\tLN:\"\$2 }' ref.fa.fai > sam.header");
    -s "aln.raw.sam"    or run("bash -c 'cat sam.header <(maf-convert sam aln-pe.maf) > aln.raw.sam'");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -bS aln.raw.sam > aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub map_with_last_se {
    verify_cmd(qw(lastdb parallel-fastq last-pair-probs samtools));
    -s "ref.fa"         or run("ln -s -f $ref ref.fa");
    -s "read_1.fq"      or run("ln -s -f $read1 read.fq");
    -s "index.suf"      or run("lastdb -m1111110 index ref.fa");
    -s "out.maf"        or run("parallel-fastq -j $nthread -k 'lastal -Q1 -d108 -e120 -i1 index' < read.fq > out.maf");
  # -s "out.maf"        or run("lastal -Q1 -d108 -e120 -i1 index read.fq > out.maf"); # sequential
    -s "aln-se.maf"     or run("ln -s -f out.maf aln-se.maf");
    -s "ref.fa.fai"     or run("samtools faidx ref.fa");
    -s "sam.header"     or run("awk '{ print \"\@SQ\\tSN:\"\$1\"\\tLN:\"\$2 }' ref.fa.fai > sam.header");
    -s "aln.raw.sam"    or run("bash -c 'cat sam.header <(maf-convert sam aln-se.maf) > aln.raw.sam'");
    -s "aln.keep.bam"   or run("samtools view -@ $nthread -bS aln.raw.sam > aln.keep.bam");
    -s "unmapped.bam"   or run("samtools view -@ $nthread -f 4 -bS aln.raw.sam > unmapped.bam");
    -s "aln.sorted.bam" or run("samtools sort -m $memory -@ $nthread -o aln.sorted.bam aln.keep.bam");
    -s "aln.dedup.bam"  or run("samtools rmdup aln.sorted.bam aln.dedup.bam");  # rmdup broken in samtools v1.0 and v1.1
    -s "aln.bam"        or run("ln -s -f aln.dedup.bam aln.bam");
    -s "aln.bam.bai"    or run("samtools index aln.bam aln.bam.bai");
}

sub summarize {
    my $summary;
    if (-s "raw.flagstat") {
        my ($reads)         = `head -n1 raw.flagstat` =~ /^(\d+)/;
        my ($mapped, $frac) = `grep mapped raw.flagstat|head -n1` =~ /^(\d+).*?([0-9.]+%)/;
        $summary .= "Total reads              = $reads\n";
        $summary .= "Properly mapped reads    = $mapped ($frac)\n";
    }
    if (-s "depth") {
        my @covs       = map { chomp; $_ } `cut -f3 depth`;
        my $bases      = scalar@covs;
        my $median_cov = median(\@covs);
        my @low_covs   = grep { $_ <= 10 } @covs;
        my @zeros      = grep { $_ == 0 } @low_covs;
        my $low_frac   = sprintf("%.3f", (scalar@low_covs / $bases * 100));
        my $zero_frac  = sprintf("%.3f", (scalar@zeros / $bases * 100));
        my $mean_cov   = sprintf("%.1f", mean(\@covs));
        my $low_regs   = low_cov_regions();

        $summary .= "Total reference bases    = $bases\n";
        $summary .= "Median base coverage     = $median_cov\n";
        $summary .= "Mean base coverage       = $mean_cov\n";
        $summary .= "Bases with zero coverage = ".scalar@zeros." ($zero_frac\%)\n";
        $summary .= "Bases with <=10 coverage = ".scalar@low_covs." ($low_frac\%)";
        $summary .= ", in $low_regs contiguous regions" if defined $low_regs;
        $summary .= "\n";
    }
    if (-s "var.sam.count") {
        my $raw_vars = `cat var.sam.count`;
        $summary .= "Raw SAMtools variants    = $raw_vars";
    }
    if (-s "var.fb.count") {
        my $raw_vars = `cat var.fb.count`;
        $summary .= "Raw FreeBayes variants   = $raw_vars";
    }
    if (-s "var.vcf") {
        my $count = `grep -v "^#" var.vcf|wc -l`;
        $summary .= "High quality variants    = $count";
    }
    write_output($summary, "summary.txt");
}

sub low_cov_regions {
    return unless -s "uncov.10";
    my @lines = `cut -f1-3 uncov.10`;
    my $count = 0;
    my ($last_ctg, $last_pos);
    for (@lines) {
        my ($ctg, $beg, $end) = split/\t/;
        $count++ if $ctg ne $last_pos || $beg ne $last_pos;
    }
    return $count;
}

sub mean {
    my ($array) = @_;
    return unless $array && @$array;
    my $sum;
    $sum += $_ for @$array;
    return $sum / scalar@$array;
}

sub median {
    my ($array) = @_;
    return unless $array && @$array;
    my @sorted = sort { $a <=> $b } @$array;
    return $sorted[int(scalar@$array/2)];
}

sub verify_cmd {
    my (@cmds) = @_;
    for my $cmd (@cmds) {
        system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
    }
}

sub verify_file {
    my (@files) = @_;
    for my $file (@files) {
        -s $file or die "File not found: $file\n";
    }
}

sub write_output {
    my ($string, $file) = @_;
    open(F, ">$file") or die "Could not open $file";
    print F $string;
    close(F);
}

sub run {
    print STDERR "Running: $_[0]\n";
    my $rc = system($_[0]);
    print STDERR "RC: $rc\n";
    $rc	== 0 or confess("FAILED: $_[0]");
}
