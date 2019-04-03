#
# The RNASeq Analysis application.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Slurp;
use File::Basename;
use IPC::Run 'run';
use JSON;
use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;
use Cwd;

my $data_url = Bio::KBase::AppService::AppConfig->data_api_url;
# my $data_url = "http://www.alpha.patricbrc.org/api";

my $script = Bio::KBase::AppService::AppScript->new(\&process_rnaseq);
my $rc = $script->run(\@ARGV);
exit $rc;

# use JSON;
# my $temp_params = JSON::decode_json(`cat /home/fangfang/P3/dev_container/modules/app_service/test_data/rna.inp`);
# process_rnaseq('RNASeq', undef, undef, $temp_params);

our $global_ws;
our $global_token;

our $shock_cutoff = 10_000;

sub process_rnaseq {
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Proc RNASeq ", Dumper($app_def, $raw_params, $params);
    my $time1 = `date`;

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
    
    $global_token = $app->token();
    $global_ws = $app->workspace;
    
    my $output_folder = $app->result_folder();
    # my $output_base   = $params->{output_file};
    
    my $recipe = $params->{recipe};
    
    # my $tmpdir = File::Temp->newdir();
    my $tmpdir = File::Temp->newdir( CLEANUP => 1 );
    # my $tmpdir = "/tmp/RNApubref";
    # my $tmpdir = "/tmp/RNAuser";
    system("chmod", "755", "$tmpdir");
    print STDERR "$tmpdir\n";
    $params = localize_params($tmpdir, $params);
    
    my @outputs;
    my $prefix = $recipe;
    my $host = 0;
    if ($recipe eq 'Rockhopper') {
        @outputs = run_rockhopper($params, $tmpdir);
    } elsif ($recipe eq 'Tuxedo' || $recipe eq 'RNA-Rocket') {
        @outputs = run_rna_rocket($params, $tmpdir, $host);
        $prefix = 'Tuxedo';
    } elsif ($recipe eq 'Host') {
        $host = 1;
        @outputs = run_rna_rocket($params, $tmpdir, $host);
        $prefix = 'Host';
    } else {
        die "Unrecognized recipe: $recipe \n";
    }
    
    print STDERR '\@outputs = '. Dumper(\@outputs);
    
    #
    # Create folders first.
    #
    for my $fent (grep { $_->[1] eq 'folder' } @outputs)
    {
	my $folder = $fent->[0];
	my $file = basename($folder);
	my $path = "$output_folder/$file";
	eval {
	    $app->workspace->create( { objects => [[$path, 'folder']] } );
	};
	if ($@)
	{
	    warn "error creating $path: $@";
	}
	else
	{
	    my $type ="txt";
	    if (opendir(my $dh, $folder))
	    {
		while (my $filename = readdir($dh))
		{
		    if ($filename =~ /\.json$/)
		    {
			my $ofile = "$folder/$filename";
			my $dest = "$path/$filename";
			print STDERR "Output folder = $folder\n";
			print STDERR "Saving $ofile => $dest ...\n";
			$app->workspace->save_file_to_file($ofile, {}, $dest, $type, 1,
							   (-s "$ofile" > $shock_cutoff ? 1 : 0), # use shock for larger files
							   $global_token);
		    }
		}
	    }
	    else
	    {
		warn "Cannot open output folder $folder: $!";
	    }
	}
    }
    for my $output (@outputs)
    {
	my($ofile, $type) = @$output;
	next if $type eq 'folder';
	
	if (! -f $ofile)
	{
	    warn "Output file '$ofile' of type '$type' does not exist\n";
	    next;
	}
	
	if ($type eq 'job_result')
	{
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
            $app->workspace->save_file_to_file("$ofile", {},"$output_folder/$filename", $type, 1);
	}
	else
	{
	    my $filename = basename($ofile);
	    print STDERR "Output folder = $output_folder\n";
	    print STDERR "Saving $ofile => $output_folder/$prefix\_$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$prefix\_$filename", $type, 1,
					       (-s "$ofile" > $shock_cutoff ? 1 : 0), # use shock for larger files
					       $global_token);
	}
    }
    my $time2 = `date`;
    write_output("Start: $time1"."End:   $time2", "$tmpdir/DONE");
}

sub run_rna_rocket {
    my ($params, $tmpdir, $host) = @_;
    
    my $cwd = getcwd();
    
    my $json = JSON::XS->new->pretty(1);
    #
    # Write job description.
    #
    my $jdesc = "$cwd/jobdesc.json";
    write_file($jdesc, $json->encode($params));
    
    my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;
    my $dat = { data_api => "$data_api/genome_feature" };
    my $override = { cufflinks => { -p => 2}, cuffdiff => {-p => 2}, cuffmerge => {-p => 2}, hisat2 => {-p => 2}, bowtie2 => {-p => 2}, stringtie => {-p => 2}};
    #
    # no pretty, ensure it's on one line
    #i
    my $pstring = encode_json($override);
    my $sstring = encode_json($dat);
    
    my $outdir = "$tmpdir/Rocket";
    
    my $exps     = params_to_exps($params);
    my $labels   = $params->{experimental_conditions};
    my $ref_id   = $params->{reference_genome_id} or die "Reference genome is required for RNA-Rocket\n";
    my $output_name = $params->{output_file} or die "Output name is required for RNA-Rocket\n";
    my $dsuffix = "_diffexp";
    my $diffexp_name = ".$output_name$dsuffix";
    my $diffexp_folder = "$outdir/.$output_name$dsuffix";
    my $diffexp_file = "$outdir/$output_name$dsuffix";
    my $ref_dir  = prepare_ref_data_rocket($ref_id, $tmpdir, $host);
    
    print "Run rna_rocket ", Dumper($exps, $labels, $tmpdir);
    
    # my $rocket = "/home/fangfang/programs/Prok-tuxedo/prok_tuxedo.py";
    my $rocket = "prok_tuxedo.py";
    verify_cmd($rocket);
    
    my @cmd = ($rocket);
    if ($host) {
        push @cmd, ("--index");
    }
    push @cmd, ("-p", $pstring);
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir);
    push @cmd, ("-d", $diffexp_name);
    push @cmd, ("--jfile", $jdesc);
    push @cmd, ("--sstring", $sstring);
    
    #push @cmd, ("-L", join(",", map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels)) if $labels && @$labels;
    #push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;
    
    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";
    
    #
    # Run directly with IPC::Run so that stdout/stderr can flow in realtime to the
    # output collection infrastructure.
    #
    my $ok = run(\@cmd);
    if (!$ok)
    {
	die "Error $? running @cmd\n";
    }
    
    #    my ($rc, $out, $err) = run_cmd(\@cmd);
    #    print STDERR "STDOUT:\n$out\n";
    #    print STDERR "STDERR:\n$err\n";
    
    
    
    run("echo $outdir && ls -ltr $outdir");
    
    #
    # Collect output and assign types.
    #
    my @outputs;
    
    #
    # BAM/BAI/GTF files are in the replicate folders.
    # We flatten the file structure in replicate folders for the
    # files we are saving.
    #
    my @sets = map { basename($_) } glob("$outdir/$ref_id/*");
    for my $set (@sets)
    {
	my @reps = map { basename($_) } glob("$outdir/$ref_id/$set/replicate*");
	
	for my $rep (@reps)
	{
	    my $path = "$outdir/$ref_id/$set/$rep";
	    #
	    # Suffix/type list for output
	    #
	    my @types = (['.bam', 'bam'], ['.bai', 'bai'], ['.gtf', 'gff'], ['.html', 'html'], ['_tracking', 'txt']);
	    for my $t (@types)
	    {
		my($suffix, $type) = @$t;
		for my $f (glob("$path/*$suffix"))
		{
		    my $base = basename($f);
		    my $nf = "$outdir/${ref_id}/${set}_${rep}_${base}";
		    if (rename($f, $nf))
		    {
			push(@outputs, [$nf, $type]);
		    }
		    else
		    {
			warn "Error renaming $f to $nf\n";
		    }
		}
	    }
	}
    }
    
    #
    # Remaining files are loaded as plain text.
    #
    for my $txt (glob("$outdir/$ref_id/*diff"))
    {
	push(@outputs, [$txt, 'txt']);
    }
    
    push @outputs, [ "$outdir/$ref_id/gene_exp.gmx", 'diffexp_input_data' ] if -s "$outdir/$ref_id/gene_exp.gmx";
    push @outputs, [ $diffexp_file, 'job_result' ] if -s $diffexp_file;
    push @outputs, [ $diffexp_folder, 'folder' ] if -e $diffexp_folder and -d $diffexp_folder;
    
    return @outputs;
}

sub run_rockhopper {
    my ($params, $tmpdir) = @_;
    
    my $exps     = params_to_exps($params);
    my $labels   = $params->{experimental_conditions};
    my $stranded = defined($params->{strand_specific}) && !$params->{strand_specific} ? 0 : 1;
    my $ref_id   = $params->{reference_genome_id};
    my $ref_dir  = prepare_ref_data($ref_id, $tmpdir) if $ref_id;
    
    print "Run rockhopper ", Dumper($exps, $labels, $tmpdir);
    
    # my $jar = "/home/fangfang/programs/Rockhopper.jar";
    my $jar = $ENV{KB_RUNTIME} . "/lib/Rockhopper.jar";
    -s $jar or die "Could not find Rockhopper: $jar\n";
    
    my $outdir = "$tmpdir/Rockhopper";
    
    my @cmd = (qw(java -Xmx1200m -cp), $jar, "Rockhopper");
    
    print STDERR '$exps = '. Dumper($exps);
    
    my @conditions = clean_labels($labels);
    
    push @cmd, qw(-SAM -TIME);
    push @cmd, qw(-s false) unless $stranded;
    push @cmd, ("-p", 1);
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir) if $ref_dir;
    push @cmd, ("-L", join(",", @conditions)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;
    
    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";
    
    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";
    
    run("echo $outdir && ls -ltr $outdir");
    
    my @outputs;
    if ($ref_id) {
        @outputs = merge_rockhoppper_results($outdir, $ref_id, $ref_dir);
        my $gmx = make_diff_exp_gene_matrix($outdir, $ref_id, \@conditions);
        push @outputs, [ $gmx, 'diffexp_input_data' ] if -s $gmx;
    } else {
        my @files = glob("$outdir/*.txt");
        @outputs = map { [ $_, 'txt' ] } @files;
    }
    
    return @outputs;
}

sub make_diff_exp_gene_matrix {
    my ($dir, $ref_id, $conditions) = @_;
    
    my $transcript = "$dir/$ref_id\_transcripts.txt";
    my $num = scalar@$conditions;
    return unless -s $transcript && $num > 1;
    
    my @genes;
    my %hash;
    my @comps;
    
    my @lines = `cat $transcript`;
    shift @lines;
    my $comps_built;
    for (@lines) {
        my @cols = split /\t/;
        my $gene = $cols[6]; next unless $gene =~ /\w/;
        my @exps = @cols[9..8+$num];
        # print join("\t", $gene, @exps) . "\n";
        push @genes, $gene;
        for (my $i = 0; $i < @exps; $i++) {
            for (my $j = $i+1; $j < @exps; $j++) {
                my $ratio = log_ratio($exps[$i], $exps[$j]);
                my $comp = comparison_name($conditions->[$i], $conditions->[$j]);
                $hash{$gene}->{$comp} = $ratio;
                push @comps, $comp unless $comps_built;
            }
        }
        $comps_built = 1;
    }
    
    my $outf = "$dir/$ref_id\_gene_exp.gmx";
    my @outlines;
    push @outlines, join("\t", 'Gene ID', @comps);
    for my $gene (@genes) {
        my $line = $gene;
        $line .= "\t".$hash{$gene}->{$_} for @comps;
        push @outlines, $line;
    }
    my $out = join("\n", @outlines)."\n";
    write_output($out, $outf);
    
    return $outf;
}

sub log_ratio {
    my ($exp1, $exp2) = @_;
    $exp1 = 0.01 if $exp1 < 0.01;
    $exp2 = 0.01 if $exp2 < 0.01;
    return sprintf("%.3f", log($exp2/$exp1) / log(2));
}

sub comparison_name {
    my ($cond1, $cond2) = @_;
    return join('|', $cond2, $cond1);
}

sub clean_labels {
    my ($labels) = @_;
    return undef unless $labels && @$labels;
    return map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels;
}

sub merge_rockhoppper_results {
    my ($dir, $gid, $ref_dir_str) = @_;
    my @outputs;
    
    my @ref_dirs = split(/,/, $ref_dir_str);
    my @ctgs = map { s/.*\///; $_ } @ref_dirs;
    
    my %types = ( "transcripts.txt" => 'txt',
		 "operons.txt"     => 'txt' );
    
    for my $result (keys %types) {
        my $type = $types{$result};
        my $outf = join("_", "$dir/$gid", $result);
        my $out;
        for my $ctg (@ctgs) {
            my $f = join("_", "$dir/$ctg", $result);
            my @lines = `cat $f`;
            my $hdr = shift @lines;
            $out ||= join("\t", 'Contig', $hdr);
            $out  .= join('', map { join("\t", $ctg, $_ ) } grep { /\S/ } @lines);
        }
        write_output($out, $outf);
        push @outputs, [ $outf, $type ];
    }
    
    my @sams = glob("$dir/*.sam");
    for my $f (@sams) {
        my $sam = basename($f);
        my $bam = $sam;
        $bam =~ s/_R[12]\.sam$/.sam/;
        $bam =~ s/\.sam$/.bam/;
        $bam = "$dir/$bam";
        # my @cmd = ("samtools", "view", "-bS", $f, "-o", $bam);
        my @cmd = ("samtools", "sort", "-T", "$f.temp", "-O", "bam","-o", $bam, $f);
        run_cmd(\@cmd);
        push @outputs, [ $bam, 'bam' ];
        @cmd = ("samtools", "index", $bam);       
        run_cmd(\@cmd);
        push @outputs, [ "$bam.bai", 'bai' ];
    }
    push @outputs, ["$dir/summary.txt", 'txt'];
    
    return @outputs;
}

sub prepare_ref_data_rocket {
    my ($gid, $basedir, $host) = @_;
    $gid or die "Missing reference genome id\n";
    
    my $dir = "$basedir/$gid";
    system("mkdir -p $dir");
    
    if ($host){
        my $tar_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.RefSeq.ht2.tar";
        my $out = curl_file($tar_url,"$dir/$gid.RefSeq.ht2.tar");
        my $fna_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.RefSeq.fna";
        $out = curl_file($fna_url,"$dir/$gid.RefSeq.fna");
        my $gff_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.RefSeq.gff";
        $out = curl_file($gff_url,"$dir/$gid.RefSeq.gff");
    }
    
    else{
        my $api_url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&http_accept=application/cufflinks+gff&limit(25000)";
        my $ftp_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.PATRIC.gff";
	
        my $url = $api_url;
        # my $url = $ftp_url;
        my $out = curl_text($url);
        write_output($out, "$dir/$gid.gff");
	
        $api_url = "$data_url/genome_sequence/?eq(genome_id,$gid)&http_accept=application/sralign+dna+fasta&limit(25000)";
        $ftp_url = "ftp://ftp.patricbrc.org/genomes/$gid/$gid.fna";
	
        $url = $api_url;
        # $url = $ftp_url;
        my $out = curl_text($url);
        # $out = break_fasta_lines($out."\n");
        $out =~ s/\n+/\n/g;
        write_output($out, "$dir/$gid.fna");
    }
    
    return $dir;
}

sub prepare_ref_data {
    my ($gid, $basedir) = @_;
    $gid or die "Missing reference genome id\n";
    
    my $url = "$data_url/genome_sequence/?eq(genome_id,$gid)&select(accession,genome_name,description,length,sequence)&sort(+accession)&http_accept=application/json&limit(25000)";
    my $json = curl_json($url);
    # print STDERR '$json = '. Dumper($json);
    my @ctgs = map { $_->{accession} } @$json;
    my %hash = map { $_->{accession} => $_ } @$json;
    
    $url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),eq(feature_type,CDS))&select(accession,start,end,strand,aa_length,patric_id,protein_id,gene,refseq_locus_tag,figfam_id,product)&sort(+accession,+start,+end)&limit(25000)&http_accept=application/json";
    $json = curl_json($url);
    
    for (@$json) {
        my $ctg = $_->{accession};
        push @{$hash{$ctg}->{cds}}, $_;
    }
    
    $url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,tRNA),eq(feature_type,rRNA)))&select(accession,start,end,strand,na_length,patric_id,protein_id,gene,refseq_locus_tag,figfam_id,product)&sort(+accession,+start,+end)&limit(25000)&http_accept=application/json";
    $json = curl_json($url);
    
    for (@$json) {
        my $ctg = $_->{accession};
        push @{$hash{$ctg}->{rna}}, $_;
    }
    
    my @dirs;
    for my $ctg (@ctgs) {
        my $dir = "$basedir/$gid/$ctg";
        system("mkdir -p $dir");
        my $ent = $hash{$ctg};
        my $cds = $ent->{cds};
        my $rna = $ent->{rna};
        my $desc = $ent->{description} || join(" ", $ent->{genome_name}, $ent->{accession});
	
        # Rockhopper only parses FASTA header of the form: >xxx|xxx|xxx|xxx|ID|
        my $fna = join("\n", ">genome|$gid|accn|$ctg|   $desc   [$ent->{genome_name}]",
                       uc($ent->{sequence}) =~ m/.{1,60}/g)."\n";
	
        my $ptt = join("\n", "$desc - 1..$ent->{length}",
		       scalar@{$ent->{cds}}.' proteins',
		       join("\t", qw(Location Strand Length PID Gene Synonym Code FIGfam Product)),
		       map { join("\t", $_->{start}."..".$_->{end},
				  $_->{strand},
				  $_->{aa_length},
				  $_->{patric_id} || $_->{protein_id},
				  # $_->{refseq_locus_tag},
				  $_->{patric_id},
				  # $_->{gene},
				  join("/", $_->{refseq_locus_tag}, $_->{gene}),
				  '-',
				  $_->{figfam_id},
				  $_->{product})
			     } @$cds
                      )."\n" if $cds && @$cds;
	
        my $rnt = join("\n", "$desc - 1..$ent->{length}",
		       scalar@{$ent->{rna}}.' RNAs',
		       join("\t", qw(Location Strand Length PID Gene Synonym Code FIGfam Product)),
		       map { join("\t", $_->{start}."..".$_->{end},
				  $_->{strand},
				  $_->{na_length},
				  $_->{patric_id} || $_->{protein_id},
				  # $_->{refseq_locus_tag},
				  $_->{patric_id},
				  # $_->{gene},
				  join("/", $_->{refseq_locus_tag}, $_->{gene}),
				  '-',
				  $_->{figfam_id},
				  $_->{product})
			     } @$rna
                      )."\n" if $rna && @$rna;
	
        write_output($fna, "$dir/$ctg.fna");
        write_output($ptt, "$dir/$ctg.ptt") if $ptt;
        write_output($rnt, "$dir/$ctg.rnt") if $rnt;
	
        push(@dirs, $dir) if $ptt;
    }
    
    return join(",",@dirs);
}

sub curl_text {
    my ($url) = @_;
    my @cmd = ("curl", curl_options(), $url);
    print STDERR join(" ", @cmd)."\n";
    my ($out) = run_cmd(\@cmd);
    return $out;
}

sub curl_file {
    my ($url, $outfile) = @_;
    my @cmd = ("curl", curl_options(), "-o", $outfile, $url);
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
    my ($cmd) = @_;
    my ($out, $err);
    run($cmd, '>', \$out, '2>', \$err)
        or die "Error running cmd=@$cmd, stdout:\n$out\nstderr:\n$err\n";
    # print STDERR "STDOUT:\n$out\n";
    # print STDERR "STDERR:\n$err\n";
    return ($out, $err);
}

sub params_to_exps {
    my ($params) = @_;
    my @exps;
    for (@{$params->{paired_end_libs}}) {
        my $index = $_->{condition} - 1;
        $index = 0 if $index < 0;
        push @{$exps[$index]}, [ $_->{read1}, $_->{read2} ];
    }
    for (@{$params->{single_end_libs}}) {
        my $index = $_->{condition} - 1;
        $index = 0 if $index < 0;
        push @{$exps[$index]}, [ $_->{read} ];
    }
    return \@exps;
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
    my $file = "$tmpdir/$base";
    # return $file; # DEBUG
    
    my $fh;
    open($fh, ">", $file) or die "Cannot open $file for writing: $!";

    print STDERR "GET WS => $tmpdir $base $id\n";
    system("ls -la $tmpdir");

    eval {
	$ws->copy_files_to_handles(1, $token, [[$id, $fh]]);
    };
    if ($@)
    {
	die "ERROR getting file $id\n$@\n";
    }
    close($fh);
    print "$id $file:\n";
    system("ls -la $tmpdir");

    return $file;
}

sub write_output {
    my ($string, $ofile) = @_;
    open(F, ">$ofile") or die "Could not open $ofile";
    print F $string;
    close(F);
}

sub break_fasta_lines {
    my ($fasta) = @_;
    my @lines = split(/\n/, $fasta);
    my @fa;
    for (@lines) {
        if (/^>/) {
            push @fa, $_;
        } else {
            push @fa, /.{1,60}/g;
        }
    }
    return join("\n", @fa);
}

sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}
