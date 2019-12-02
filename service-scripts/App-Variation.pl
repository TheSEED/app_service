#
# The Variation Analysis application.
#

use strict;
use Carp;
use Cwd qw(abs_path getcwd);
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use JSON;
use P3DataAPI;

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;

my $script_dir = abs_path(dirname(__FILE__));
my $data_url = Bio::KBase::AppService::AppConfig->data_api_url;
# my $data_url = "https://www.patricbrc.org/api";
my $script = Bio::KBase::AppService::AppScript->new(\&process_variation_data, \&preflight);
my $rc = $script->run(\@ARGV);
exit $rc;

our $global_ws;
our $global_token;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $time = 86400 * 2;

    my $pf = {
	cpu => 4,
	memory => "128G",
	runtime => $time,
	storage => 0,
	is_control_task => 0,
    };
    return $pf;
}



sub process_variation_data {
    my ($app, $app_def, $raw_params, $params) = @_;

    #
    # Redirect tmp to large NFS if more than 4 input files.
    # (HACK)
    #
    
    my $file_count = count_params_files($params);
    print STDERR "File count: $file_count\n";
    my $bigtmp = "/vol/patric3/tmp";
    if ($file_count > 4 && -d $bigtmp)
    {
	print STDERR "Changing tmp from $ENV{TEMPDIR} to $bigtmp\n";
	$ENV{TEMPDIR} = $ENV{TMPDIR} = $bigtmp;
    }

    print "Proc variation data ", Dumper($app_def, $raw_params, $params);
    my $time1 = `date`;

    $global_token = $app->token();
    $global_ws = $app->workspace;

    my $output_folder = $app->result_folder();

    my $run_dir = getcwd();

    my $tmpdir = File::Temp->newdir();
    # my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    # my $tmpdir = "/tmp/oIGe_LLBbt";
    # my $tmpdir = "/disks/tmp/var_bam";
    # my $tmpdir = "/disks/tmp/var_bam1";
    # my $tmpdir = "/disks/tmp/var_debug";

    system("chmod", "755", "$tmpdir");
    print STDERR "tmpdir=$tmpdir\n";

    print STDERR '$params = '. Dumper($params);
    $params = localize_params($tmpdir, $params);
    $params = parse_bam_files($tmpdir, $params);
    print STDERR '$params = '. Dumper($params);
    # exit;

    my $ref_id = $params->{reference_genome_id} or die "Reference genome is required for variation analysis\n";

    my $has_gbk = prepare_ref_data($ref_id, $tmpdir);

    my $mapper = $params->{mapper} || 'bwa_mem';
    my $caller = $params->{caller} || 'freebayes';

    my $map = "$script_dir/var-map.pl"; verify_cmd($map);

    my $threads = $ENV{P3_ALLOCATED_CPU} // 2;

    my @basecmd = ($map);
    push @basecmd, ("-a", $mapper);
    push @basecmd, ("--vc", $caller);
    push @basecmd, ("--threads", $threads);
    push @basecmd, "$tmpdir/$ref_id/$ref_id.fna";

    my $lib_txt = "$tmpdir/libs.txt";
    open(LIBS, ">$lib_txt") or die "Could not open $lib_txt";
    print LIBS "Library\tReads\n";
    my ($pe_no, $se_no);
    my @libs;
    for (@{$params->{paired_end_libs}}) {
        my $lib = "PE". ++$pe_no;
        my $outdir = "$tmpdir/$lib";
        push @libs, $lib;
        my @cmd = @basecmd;
        push @cmd, ("-o", $outdir);
        push @cmd, ($_->{read1}, $_->{read2});
        print LIBS $lib."\t".join(",", basename($_->{read1}), basename($_->{read2}))."\n";
        run_cmd(\@cmd, 1);
    }
    for (@{$params->{single_end_libs}}) {
        my $lib = "SE". ++$se_no;
        my $outdir = "$tmpdir/$lib";
        push @libs, $lib;
        my @cmd = @basecmd;
        push @cmd, ("-o", $outdir);
        push @cmd, $_->{read};
        print LIBS $lib."\t".basename($_->{read})."\n";
        run_cmd(\@cmd, 1);
    }
    close(LIBS);

    for (@libs) {
        run_snpeff($tmpdir, $ref_id, $_) if $has_gbk;
        run_var_annotate($tmpdir, $ref_id, $_);
        link_snpeff_annotate($tmpdir, $ref_id, $_) if $has_gbk;
        system("ln -s $tmpdir/$_/aln.bam $tmpdir/$_.aln.bam") if -s "$tmpdir/$_/aln.bam";
        system("ln -s $tmpdir/$_/aln.bam.bai $tmpdir/$_.aln.bam.bai") if -s "$tmpdir/$_/aln.bam.bai";
        system("cp $tmpdir/$_/var.vcf $tmpdir/$_.var.vcf") if -s "$tmpdir/$_/var.vcf";
        system("cp $tmpdir/$_/var.vcf.gz $tmpdir/$_.var.vcf.gz") if -s "$tmpdir/$_/var.vcf.gz";
        system("cp $tmpdir/$_/var.vcf.gz.tbi $tmpdir/$_.var.vcf.gz.tbi") if -s "$tmpdir/$_/var.vcf.gz.tbi";
        system("cp $tmpdir/$_/var.annotated.tsv $tmpdir/$_.var.annotated.tsv") if -s "$tmpdir/$_/var.annotated.tsv";
        system("cp $tmpdir/$_/var.annotated.raw.tsv $tmpdir/$_.var.annotated.tsv") if ! -s "$tmpdir/$_/var.annotated.tsv" && -s "$tmpdir/$_/var.annotated.raw.tsv";
        system("cp $tmpdir/$_/var.snpEff.vcf $tmpdir/$_.var.snpEff.vcf") if -s "$tmpdir/$_/var.snpEff.vcf";
        system("cat $tmpdir/$_/consensus | sed 's/^>/>$_./g' > $tmpdir/$_.consensus.fa") if -s "$tmpdir/$_/consensus";
    }

    run_var_combine($tmpdir, \@libs);
    summarize($tmpdir, \@libs, $mapper, $caller);

    my @outputs;
    push @outputs, map { [ $_, 'txt' ] } glob("$tmpdir/*.tsv $tmpdir/*.txt");
    push @outputs, map { [ $_, 'vcf' ] } glob("$tmpdir/*.vcf");
    push @outputs, map { [ $_, 'html'] } glob("$tmpdir/*.html");
    push @outputs, map { [ $_, 'bam' ] } glob("$tmpdir/*.bam");
    push @outputs, map { [ $_, 'contigs' ] } glob("$tmpdir/*.consensus.fa");
    push @outputs, map { [ $_, 'unspecified' ] } glob("$tmpdir/*.tbi $tmpdir/*.vcf.gz $tmpdir/*.bam.bai");

    print STDERR '\@outputs = '. Dumper(\@outputs);
    # return @outputs;

    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$filename", $type, 1,
					       (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       # (-s "$ofile" > 20_000_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

    my $time2 = `date`;
    write_output("Start: $time1"."End:   $time2", "$tmpdir/DONE");

    chdir($run_dir);
}

sub run_var_annotate {
    my ($tmpdir, $ref_id, $lib) = @_;
    my $annotate = "$script_dir/var-annotate.pl"; verify_cmd($annotate);

    my $fna = "$tmpdir/$ref_id/$ref_id.fna";
    my $gff = "$tmpdir/$ref_id/$ref_id.gff";
    my $dir = "$tmpdir/$lib";
    my @cmd = split(' ', "$annotate --header $fna $gff $dir/var.snpEff.raw.vcf");
    my ($out) = run_cmd(\@cmd, 0);
    write_output($out, "$dir/var.annotated.raw.tsv");
}

sub run_snpeff {
    my ($tmpdir, $ref_id, $lib) = @_;
    my $genome_name = get_genome_name($ref_id);
    my @accessions = get_genome_accessions($ref_id);
    my $dir = "$tmpdir/$lib";
    my $config = "$dir/snpEff.config";
    open(F, ">$config") or die "Could not open $config";
    print F "data.dir = $tmpdir\n\n";
    print F "$ref_id.genome : $genome_name\n";
    print F "  $ref_id.chromosomes : ". join(",", @accessions)."\n";
    close(F);
    my $here = getcwd();
    chdir($dir);
    my @cmd = split(' ', "snpEff.sh build -c $config -genbank -v $ref_id");
    run_cmd(\@cmd, 1);
    @cmd = split(' ', "snpEff.sh eff -no-downstream -no-upstream -no-utr -o vcf -c $config $ref_id var.vcf");
    my ($out) = run_cmd(\@cmd, 0);
    write_output($out, "var.snpEff.raw.vcf");
    chdir($here);
}

sub link_snpeff_annotate {
    my ($tmpdir, $ref_id, $lib) = @_;

    my $url = "$data_url/genome_feature/?and(eq(genome_id,$ref_id),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&select(patric_id,alt_locus_tag)&http_accept=application/json&limit(25000)";
    my $data = curl_json($url);
    my %vbi2peg = map { $_->{alt_locus_tag} => $_->{patric_id} } @$data;

    my $dir = "$tmpdir/$lib";
    my $eff_raw = "$dir/var.snpEff.raw.vcf";
    my $ann_raw = "$dir/var.annotated.raw.tsv";
    return unless -s $eff_raw && -s $ann_raw;

    my %var2eff;
    my $eff = "$dir/var.snpEff.vcf";
    my $ann = "$dir/var.annotated.tsv";
    my @lines = `cat $eff_raw`;
    open(EFF, ">$eff") or die "Could not open $eff";
    for my $line (@lines) {
        if ($line =~ /EFF=\S+\|(VBI\w+)/) {
            my $vbi = $1;
            my $peg = $vbi2peg{$vbi}; $peg =~ s/fig\|//;
            $line =~ s/\|$vbi/\|$peg/;
        }
        print EFF $line;
        my ($ctg, $pos) = split(/\t/, $line);
        if ($line =~ /EFF=(\w+)?\((\S+?)\|/) {
            $var2eff{"$ctg,$pos"} = [$1, $2]; # EFF=missense_variant(MODERATE|MISSENSE|tCt/tTt...)
        }
    }
    close(EFF);

    @lines = `cat $ann_raw`;
    open(ANN, ">$ann") or die "Could not open $ann";
    for (@lines) {
        chomp;
        print ANN $_;
        if (/^Sample/) {
            print ANN "\t".join("\t", 'snpEff_type', 'snpEff_impact');
        } elsif (! /^#/) {
            my ($lib, $ctg, $pos) = split(/\t/);
            my $snpeff = $var2eff{"$ctg,$pos"};
            print ANN "\t".join("\t", @$snpeff) if $snpeff;
        }
        print ANN "\n";
    }
    close(ANN);

}

sub run_var_combine {
    my ($tmpdir, $libs) = @_;
    my $combine = "$script_dir/var-combine.pl"; verify_cmd($combine);
    my @files = map { -s "$tmpdir/$_/var.annotated.tsv" ? "$tmpdir/$_/var.annotated.tsv" :
                      -s "$tmpdir/$_/var.annotated.raw.tsv" ? "$tmpdir/$_/var.annotated.raw.tsv" :
                      undef } @$libs;
    if (@files == 0) {
        print STDERR "No var.annotated.[raw.]tsv files to combine\n";
        return;
    }
    my $cmd = join(" ", @files);
    sysrun("cat $cmd | $combine --header > $tmpdir/all.var.tsv");
    sysrun("cat $cmd | $combine --html > $tmpdir/all.var.html");
}

sub summarize {
    my ($tmpdir, $libs, $mapper, $caller) = @_;
    my $summary;
    my $total = 0;
    my $combined = "$tmpdir/all.var.tsv";
    if (-s $combined) {
        $total = `wc -l $combined`; chomp($total);
        $total--;
    }
    $summary .= "A total of $total variants have been found.";
    my $n_libs = scalar @$libs;
    if ($n_libs > 1) {
        my $shared = `grep "^$n_libs" $combined |wc -l`; chomp($shared);
        $summary .= " $shared of these variants are identified in all read libraries.";
    }
    $summary .= "\n\nOutput summary:\n";
    $summary .= "all.var.tsv             - combined sheet of annotated variants from all libraries\n";
    $summary .= "all.var.html            - sortable HTML table of all annotated variants\n";
    $summary .= "libs.txt                - mapping from read library to file(s)\n";
    $summary .= "<LIB>.aln.bam           - $mapper aligned reads for a read library\n";
    $summary .= "<LIB>.var.vcf           - $caller generated high quality variants for a read library\n";
    $summary .= "<LIB>.var.snpEff.vcf    - snpEff augmented VCF with variant effect prediction\n";
    $summary .= "<LIB>.var.annotated.tsv - PATRIC annotated variants in a spreadsheet\n";
    $summary .= "<LIB> denotes the name of a read library (e.g., PE1 for paired end 1, SE3 for single end 3).\n";
    $summary .= "\nResults by read library:\n";

    my $lib_txt = "$tmpdir/libs.txt";
    my @lines = `tail -n $n_libs $lib_txt`;
    my $i;
    for (@$libs) {
        my ($lib, $reads) = split(/\t/, $lines[$i]); chomp($reads);
        $i++;
        $summary .= "\n[$i] $lib ($reads)\n\n";
        my $sumfile = "$tmpdir/$lib/summary.txt";
        if (-s $sumfile) {
            $summary .= "    $_" for `cat $sumfile`;
        }
    }
    $summary .= "\n";
    write_output($summary, "$tmpdir/summary.txt");
}

sub get_genome_name {
    my ($gid) = @_;
    ($gid) = $gid =~ /(\d+\.\d+)/;
    my $url = "$data_url/genome/?eq(genome_id,$gid)&select(genome_name)&http_accept=application/json";
    my $data = curl_json($url);
    return $data->[0]->{genome_name};
}

sub get_genome_accessions {
    my ($gid) = @_;
    ($gid) = $gid =~ /(\d+\.\d+)/;
    my $url = "$data_url/genome_sequence/?eq(genome_id,$gid)&select(accession)&sort(+accession)&http_accept=application/json";
    my $data = curl_json($url);
    my @accs = map { $_->{accession} } @$data;
    wantarray ? @accs : \@accs;
}

sub prepare_ref_data {
    my ($gid, $basedir) = @_;
    $gid or die "Missing reference genome id\n";

    my $dir = "$basedir/$gid";
    sysrun("mkdir -p $dir");

    # my $api_url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&http_accept=application/cufflinks+gff&limit(25000)";
    my $api_url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&http_accept=application/gff&limit(25000)";
    my $ftp_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.PATRIC.gff";

    my $url = $api_url;
    # my $url = $ftp_url;
    my $out = curl_text($url);
    $out =~ s/^accn\|//gm;
    write_output($out, "$dir/$gid.gff");

    $api_url = "$data_url/genome_sequence/?eq(genome_id,$gid)&http_accept=application/sralign+dna+fasta&limit(25000)";
    $ftp_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.fna";

    $url = $api_url;
    # $url = $ftp_url;
    my $out = curl_text($url);
    # $out = break_fasta_lines($out."\n");
    $out =~ s/\n+/\n/g;
    write_output($out, "$dir/$gid.fna");

    # snpEff data
    # $ftp_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.PATRIC.gbf";
    # $url = $ftp_url;
    # my $out = curl_text($url);     
    # my $out = `curl $url`;
    # write_output($out, "$dir/genes.gbk") if $out;
    # my $has_gbk = $out ? 1 : 0;

    #Generate genbank file

    {
	my $api = P3DataAPI->new();
	my $gto = $api->gto_of($gid);
	$gto or die "Could not retreive GTO for $gid\n";
	$gto->destroy_to_file("$dir/gid.gto");
	-f "$dir/gid.gto" or die "Could not create $dir/$gid.gto from gto\n";
    }
    sysrun("rast_export_genome", "-i", "$dir/$gid.gto", "-o", "$dir/genes.gbk", "genbank");

    my $has_gbk = 0;    
    $has_gbk = 1 if -s "$dir/genes.gbk";

    return $has_gbk;
}

sub curl_text {
    my ($url) = @_;
    my @cmd = ("curl", curl_options(), $url);
    print STDERR join(" ", @cmd)."\n";
    my ($out) = run_cmd(\@cmd);
    return $out;
}

sub curl_json {
    my ($url) = @_;
    my $out = curl_text($url);
    my $hash = JSON::decode_json($out);
    return $hash;
}

sub curl_options {
    my @opts;
    my $token = get_token()->token;
    push(@opts, "-H", "Authorization: $token");
    push(@opts, "-H", "Content-Type: multipart/form-data");
    return @opts;
}

sub run_cmd {
    my ($cmd, $verbose) = @_;
    my ($out, $err);
    print STDERR "cmd = ", join(" ", @$cmd) . "\n\n" if $verbose;
    run($cmd, '>', \$out, '2>', \$err)
        or die "Error running cmd=@$cmd, stdout:\n$out\nstderr:\n$err\n";
    print STDERR "STDOUT:\n$out\n" if $verbose;
    print STDERR "STDERR:\n$err\n" if $verbose;
    return ($out, $err);
}

sub parse_bam_files {
    my ($tmpdir, $params) = @_;
    for my $lib (@{$params->{single_end_libs}}) {
        if ($lib->{read} =~ /(.*)\.bam$/) {
            my $input = $lib->{read};
            my $pe1 = "$1_R1.fq";
            my $pe2 = "$1_R2.fq";
            sysrun("samtools sort -n $input | samtools fastq -1 $pe1 -2 $pe2 -");
            if (-s $pe1 && -s $pe2) {
                push @{$params->{paired_end_libs}}, { read1 => $pe1, read2 => $pe2 };
            }
            $lib->{read} = undef;
        }
    }
    $params->{single_end_libs} = [ grep { defined($_->{read}) } @{$params->{single_end_libs}} ];
    return $params;
}

sub localize_params {
    my ($tmpdir, $params) = @_;
    for (@{$params->{paired_end_libs}}) {
        $_->{read1} = get_ws_file($tmpdir, $_->{read1}) if $_->{read1};
        $_->{read2} = get_ws_file($tmpdir, $_->{read2}) if $_->{read2};
    }
    for (@{$params->{single_end_libs}}) {
        $_->{read} = get_ws_file($tmpdir, $_->{read}) if $_->{read};
    }
    return $params;
}


sub count_params_files {
    my ($params) = @_;
    my $count = 0;
    if (ref($params->{paired_end_libs}))
    {
	$count += 2 * @{$params->{paired_end_libs}};
    }
    if (ref($params->{single_end_libs}))
    {
	$count += @{$params->{single_end_libs}};
    }
    return $count;
}

sub get_ws {
    return $global_ws;
}

sub get_token {
    return $global_token;
}

sub get_ws_file {
    my ($tmpdir, $id) = @_;
    # return $id; # DEBUG
    my $ws = get_ws();
    my $token = get_token();

    my $base = basename($id);
    $base =~ s/\s/_/g;
    my $file = "$tmpdir/$base";
    # return $file; # DEBUG

    my $fh;
    open($fh, ">", $file) or die "Cannot open $file for writing: $!";

    print STDERR "GET WS => $tmpdir $base $id\n";

    eval {
	$ws->copy_files_to_handles(1, $token, [[$id, $fh]]);
    };
    if ($@)
    {
	die "ERROR getting file $id\n$@\n";
    }
    close($fh);

    return $file;
}

sub write_output {
    my ($string, $ofile) = @_;
    open(F, ">$ofile") or die "Could not open $ofile";
    print F $string;
    close(F);
}

sub verify_cmd {
    my ($cmd) = @_;
    print STDERR "verifying executable $cmd ...\n";
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}

sub sysrun { system(@_) == 0 or confess("Command FAILED: ". join(" ", @_)); }
