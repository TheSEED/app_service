#
# The RNASeq Analysis application.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use JSON;

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

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

sub process_rnaseq {
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Proc RNASeq ", Dumper($app_def, $raw_params, $params);

    $global_token = $app->token();
    $global_ws = $app->workspace;
    my $output_folder = $app->result_folder();
    my $output_path = $params->{output_path};
    my $output_base = $params->{output_file};

    my $recipe = $params->{recipe};
    
    # my $tmpdir = File::Temp->newdir();
    my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    # my $tmpdir = "/tmp/ZKLUBOtpuf";
    # my $tmpdir = "/tmp/_jfhupHJs8";
    system("chmod 755 $tmpdir");
    print STDERR "$tmpdir\n";
    $params = localize_params($tmpdir, $params);

    my @outputs;
    if ($recipe eq 'Rockhopper') {
        @outputs = run_rockhopper($params, $tmpdir);
    } elsif ($recipe eq 'RNA-Rocket') {
        @outputs = run_rna_rocket($params, $tmpdir);
    } else {
        die "Unrecognized recipe: $recipe \n";
    }

    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$recipe\_$filename", $type, 1,
					       # (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       (-s "$ofile" > 20_000_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

}

sub run_rna_rocket {
    my ($params, $tmpdir) = @_;

    my $exps     = params_to_exps($params);
    my $labels   = $params->{experimental_conditions};
    my $ref_id   = $params->{reference_genome_id} or die "Reference genome is required for RNA-Rocket\n";
    my $ref_dir  = prepare_ref_data_rocket($ref_id, $tmpdir);

    print "Run rna_rocket ", Dumper($exps, $labels, $tmpdir);
    
    my $rocket = "/home/fangfang/programs/Prok-tuxedo/prok_tuxedo.py";
    -e $rocket or die "Could not find RNA-Rocket: $rocket\n";

    my $outdir = "$tmpdir/Rocket";

    my @cmd = ($rocket);
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir);
    push @cmd, ("-L", join(",", map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;

    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";

    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";

    run("echo $outdir && ls -ltr $outdir");

    my @files = glob("$outdir/$ref_id/gene* $outdir/$ref_id/*/replicate*/*tracking $outdir/$ref_id/*/replicate*/*gtf");
    print STDERR '\@files = '. Dumper(\@files);
    my @new_files;
    for (@files) {
        if (m|/\S*?/replicate\d/|) {
            my $fname = $_; $fname =~ s|/(\S*?)/(replicate\d)/|/$1\_$2\_|;
            run_cmd(["mv", $_, $fname]);
            push @new_files, $fname;
        } else {
            push @new_files, $_;
        }
    }
    my @outputs = map { [ $_, 'txt' ] } @new_files;

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

    my $jar = "/home/fangfang/programs/Rockhopper.jar";
    -s $jar or die "Could not find Rockhopper: $jar\n";

    my $outdir = "$tmpdir/Rockhopper";

    my @cmd = (qw(java -Xmx1200m -cp), $jar, "Rockhopper");

    print STDERR '$exps = '. Dumper($exps);
    
    # push @cmd, qw(-SAM -TIME);
    push @cmd, qw(-s false) unless $stranded;
    push @cmd, ("-o", $outdir);
    push @cmd, ("-g", $ref_dir) if $ref_dir;
    push @cmd, ("-L", join(",", map { s/^\W+//; s/\W+$//; s/\W+/_/g; $_ } @$labels)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;

    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";

    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";

    run("echo $outdir && ls -ltr $outdir");

    my @outputs;
    if ($ref_id) {
        @outputs = merge_results($outdir, $ref_id, $ref_dir);
    } else {
        my @files = glob("$outdir/*.txt");
        @outputs = map { [ $_, 'txt' ] } @files;
    }
    return @outputs;
}

sub merge_results {
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
            $out  .= join('', map { join("\t", $ctg, $_ ) } @lines);
        }
        write_output($out, $outf);
        push @outputs, [ $outf, $type ];
    }
    push @outputs, ["$dir/summary.txt", 'txt'];
    return @outputs;
}

sub prepare_ref_data_rocket {
    my ($gid, $basedir) = @_;
    $gid or die "Missing reference genome id\n";

    my $dir = "$basedir/$gid";
    system("mkdir -p $dir");

    my $api_url = "$data_url/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),or(eq(feature_type,CDS),eq(feature_type,tRNA),eq(feature_type,rRNA)))&sort(+accession,+start,+end)&http_accept=application/gff&limit(25000)";
    my $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.PATRIC.gff";

    my $url = $ftp_url;
    my $out = curl_text($url);
    write_output($out, "$dir/$gid.gff");
    
    $api_url = "$data_url/genome_sequence/?eq(genome_id,$gid)&http_accept=application/dna+fasta&limit(25000)";
    $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.fna";
    
    # $url = $api_url;
    $url = $ftp_url;
    my $out = curl_text($url);
    # $out = break_fasta_lines($out."\n");
    $out =~ s/\n+/\n/g;
    write_output($out, "$dir/$gid.fna");

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

        # Rockhopper only parses FASTA header of the form: >xxx|xxx|xxx|xxx|ID|
        my $fna = join("\n", ">genome|$gid|accn|$ctg|   $ent->{description}   [$ent->{genome_name}]",
                       uc($ent->{sequence}) =~ m/.{1,60}/g)."\n";

        my $ptt = join("\n", "$ent->{description} - 1..$ent->{length}",
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
                      ) if $cds && @$cds;

        my $rnt = join("\n", "$ent->{description} - 1..$ent->{length}",
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
                      ) if $rna && @$rna;

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


sub get_ws {
    return $global_ws;
}

sub get_token {
    return $global_token;
}
 
sub get_ws_file {
    my ($tmpdir, $id) = @_;
    # return $id;
    my $ws = get_ws();
    my $token = get_token();

    my $base = basename($id);
    my $file = "$tmpdir/$base";
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

