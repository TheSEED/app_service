#
# The Genome Proteome Comparison application.
#

use strict;
use Carp;
use Cwd;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use JSON;
use Storable;
use URI::Escape;

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

use bidir_best_hits;

my $blastp  = "blastp";
my $circos  = "circos";
my $openssl = "openssl";

verify_cmd($blastp) and verify_cmd($circos) and verify_cmd($openssl);

my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;
# my $data_api = 'http://www.alpha.patricbrc.org/api';

my $script = Bio::KBase::AppService::AppScript->new(\&process_proteomes);
my $rc = $script->run(\@ARGV);
exit $rc;

# my $temp_params = JSON::decode_json(`cat /home/fangfang/P3/dev_container/modules/app_service/test_data/gencomp.inp`);
# process_rnaseq('GenomeComparison', undef, undef, $temp_params);

our $global_ws;
our $global_token;

sub process_proteomes {
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Proc proteomes ", Dumper($app_def, $raw_params, $params);

    $global_token = $app->token();
    $global_ws = $app->workspace;
    my $output_folder = $app->result_folder();
    my $output_path = $params->{output_path};
    my $output_base = $params->{output_file};

    my $tmpdir = File::Temp->newdir();
    # my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    # my $tmpdir = "/tmp/uzC2oDT0Xu";
    # my $tmpdir = "/tmp/9nGp1LR4k3";
    # my $tmpdir = "/disks/tmp/comp_debug";
    print STDERR "tmpdir = $tmpdir\n";

    my ($genomes, $tracks) = get_genome_faa($tmpdir, $params);

    my ($ref_type, $ref_name) = get_ref_type($params);

    my @outputs = run_find_bdbh($tmpdir, $genomes, $tracks, $ref_type, $ref_name, $params);

    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$filename", $type, 1,
					       # (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       # (-s "$ofile" > 20_000_000 ? 1 : 0), # use shock for larger files
					       0, # do not use shock as it breaks the front end
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }
}

sub run_find_bdbh {
    my ($tmpdir, $genomes, $tracks, $ref_type, $ref_name, $params) = @_;

    my $feaH = get_feature_hash($params); # from genome_ids and user_feature_groups

    my $nproc = 2;
    # my $nproc = get_num_procs();
    my $opts = { min_cover     => $params->{min_seq_cov},
                 min_positives => $params->{min_positives},
                 min_ident     => $params->{min_ident},
                 max_e_val     => $params->{max_e_val},
                 program       => 'blastp',
                 blast_opts    => "-a $nproc",
                 verbose       => 1
               };
    print STDERR "BBH options: ", Dumper($opts);

    my @orgs = @$genomes;
    my ($circos_ref, @circos_comps);
    my @fids;
    my %hits;

    my @ref_fields  = qw(contig gene aa_length patric_id locus_tag gene_name function start end strand);
    my @comp_fields = qw(hit contig gene aa_length patric_id locus_tag gene_name function percent_identity seq_coverage); # e_value not directly available for Gary's tool
    my @fields      = map { 'ref_genome_'.$_ } @ref_fields;
    my @headers     = (filename_to_genome_name($orgs[0]));
    push @headers, (undef) x $#ref_fields;

    my $ref = shift @orgs;
    my $gi = 0;

    my @user_ref_contigs;
    my $user_ref_contig_num  = 0;
    my $user_ref_contig_len  = 0;
    my $user_ref_contig_name = 'UNKNOWN';

    for my $g (@orgs) {
        $gi++;
        print STDERR "Run bidir_best_hits::bbh: ", join(" <=> ", $ref, $g)."\n";
        my ($bbh, $log1, $log2) = bidir_best_hits::bbh($ref, $g, $opts);
        # print Dumper($bbh);
        # print Dumper($log1);
        # print Dumper($log2);
        # store($log1, "$tmpdir/STORE.$gi");
        # my $log1 = retrieve("$tmpdir/STORE.$gi");
        next unless $log1 && @$log1;

        push @fields, "comp_genome_$gi\_$_" for @comp_fields;
        push @headers, filename_to_genome_name($g);
        push @headers, (undef) x $#comp_fields;

        if (!@fids) {
            @fids = map { $_->[0] } @$log1; # reference feature patric_ids
            for (@$log1) {
                my ($id, $len) = @$_;
                if ($ref_type eq 'user_genome') {
                    # option 1: user seqs on separate contigs
                    # my $unknown_contig = $user_ref_contig_name . ++$user_ref_contig_num;
                    # option 2: line up user seqs with 30bp gaps in a single artificial contig
                    my $unknown_contig = $user_ref_contig_name;
                    $hits{$id} = { ref_genome_patric_id => $id,
                                   ref_genome_contig    => $unknown_contig,
                                   # option 1:
                                   # ref_genome_start     => 1,
                                   # ref_genome_end       => $len*3 + 3 };
                                   # option 2:
                                   ref_genome_start     => $user_ref_contig_len + 1,
                                   ref_genome_end       => $user_ref_contig_len + $len*3 + 3 };
                    # option 1:
                    # push @user_ref_contigs, [ $unknown_contig, $id, $len*3+3 ];
                    # option 2:
                    $user_ref_contig_len += $len*3 + 3 + 60;
                } else {        # genome_id or user_feature_group
                    my $id_num = patric_id_to_number($id);
                    $hits{$id} = { ref_genome_patric_id => $id,
                                   ref_genome_gene      => $id_num,
                                   ref_genome_aa_length => $len,
                                   ref_genome_contig    => $feaH->{$id}->{accession},
                                   ref_genome_locus_tag => $feaH->{$id}->{refseq_locus_tag},
                                   ref_genome_gene_name => $feaH->{$id}->{gene},
                                   ref_genome_function  => $feaH->{$id}->{product},
                                   ref_genome_start     => $feaH->{$id}->{start},
                                   ref_genome_end       => $feaH->{$id}->{end},
                                   ref_genome_strand    => $feaH->{$id}->{strand} };
                }

                push @$circos_ref, [ $hits{$id}->{ref_genome_contig},
                                     $hits{$id}->{ref_genome_start},
                                     $hits{$id}->{ref_genome_end},
                                     "id=$id" ];
            }
            # option 2:
            @user_ref_contigs = [ $user_ref_contig_name, 'USER_FASTA', $user_ref_contig_len ];
        }

        my @circos_org;
        for (@$log1) {
            my ($id, $len, $arrow, $s_id, $s_len, $fract_id, $fract_pos, $q_coverage, $s_coverage) = @$_;
            next if $fract_id < $params->{min_ident};
            next if $q_coverage < $params->{min_seq_cov} || $s_coverage < $params->{min_seq_cov},;

            my $hit_type = $arrow eq '<->' ? 'bi (<->)' :
                           $arrow eq ' ->' ? 'uni (->)' : undef;
            next unless $s_id;

            my $s_id_num = patric_id_to_number($s_id);

            my %match = ( hit              => $hit_type,
                          patric_id        => $s_id,
                          gene             => $s_id_num,
                          aa_length        => $s_len,
                          contig           => $feaH->{$s_id}->{accession},
                          locus_tag        => $feaH->{$s_id}->{refseq_locus_tag},
                          gene_name        => $feaH->{$s_id}->{gene},
                          function         => $feaH->{$s_id}->{product},
                          percent_identity => $fract_id,
                          seq_coverage     => $s_coverage );

            while (my ($k,$v) = each %match) {
                $hits{$id}->{"comp_genome_$gi\_$k"} = $v;
            }

            my $score = sprintf("%.2f", $fract_id * 100);
            $score = -$score if $hit_type eq 'uni'; # use negative score to invoke color rules for unidirectional best hit

            push @circos_org, [ $hits{$id}->{ref_genome_contig},
                                $hits{$id}->{ref_genome_start},
                                $hits{$id}->{ref_genome_end},
                                $score,
                                "id=$s_id" ];
        }
        push @circos_comps, \@circos_org;
    }

    print "REF_TYPE = $ref_type\n";
    my $contigs = $ref_type eq 'user_genome' ? \@user_ref_contigs :
                  $ref_type eq 'genome_id' ?    get_genome_contigs($ref) :
                                                get_feature_group_contigs($ref_name);

    my @outputs;

    # generate big comparison table
    my $ofile = "$tmpdir/genome_comparison.txt";
    my @rows = (\@headers, \@fields);
    for my $fid (@fids) {
        push @rows, [ map { $hits{$fid}->{$_} } @fields ];
    }
    write_table(\@rows, $ofile);
    push @outputs, [ $ofile, 'genome_comparison_table' ];

    $ofile = "$tmpdir/genome_comparison.json";
    my %is_user_genome;
    my $name_hash = { ref_genome => filename_to_genome_name($genomes->[0]) };
    for (my $i = 1; $i <= @orgs; $i++) {
        $name_hash->{"comp_genome_$i"} = filename_to_genome_name($orgs[$i-1]);
        $is_user_genome{$i} = 1 if $tracks->[$i] =~ /user fasta/;
    }
    my @json_rows = map { $hits{$_} } @fids;
    my $dump = { genome_names => $name_hash, feature_matches => \@json_rows };
    write_output(encode_json($dump), $ofile);
    push @outputs, [ $ofile, 'json' ];

    # generate circos files
    # my $circos_dir = $tmpdir;
    my $circos_dir = "$tmpdir/circos";
    system("mkdir -p $circos_dir");

    my $circos_opts;
    $ofile = "$circos_dir/ref_genome.txt";
    $circos_opts->{ref_genome} = $ofile;
    $circos_opts->{ref_type} = $ref_type;
    write_table($circos_ref, $ofile);
    push @outputs, [ $ofile, 'txt' ];

    my $i = 0;
    for my $comp (@circos_comps) {
        my $ofile = "$circos_dir/comp_genome_".++$i.".txt";
        push @{$circos_opts->{comp_genomes}}, $ofile;
        write_table($comp, $ofile);
        push @outputs, [ $ofile, 'txt' ];
    }
    $circos_opts->{is_user_genome} = \%is_user_genome;

    $ofile ="$circos_dir/karyotype.txt";
    $circos_opts->{karyotype} = $ofile;
    @rows = ();
    my $index = 0;
    for (@$contigs) {
        my ($acc, $name, $len) = @$_;
        $name =~ s/\s+/_/g;
        # push @rows, ['chr', '-', $acc, $name, 0, $len, 'grey'];
        # push @rows, ['chr', '-', $acc, $acc, 0, $len, 'grey'];
        push @rows, ['chr', '-', $acc, ++$index, 0, $len, 'grey'];
    }
    write_table(\@rows, $ofile);
    push @outputs, [ $ofile, 'txt' ];

    $ofile ="$circos_dir/large.tiles.txt";
    $circos_opts->{large_tiles} = $ofile;
    @rows = map { [ $_->[0], 0, $_->[2] ] } @$contigs;
    write_table(\@rows, $ofile);
    push @outputs, [ $ofile, 'txt' ];

    my $final = color_legend()."\n";
    $final .= track_legend($tracks);

    my $conf = prepare_circos_configs($circos_dir, $circos_opts);
    my @cmd = ($circos, '-conf', $conf, '-outputdir', $circos_dir);
    my ($out, $err) = run_cmd(\@cmd);
    $ofile = "$circos_dir/circos.svg";
    -s $ofile or die "Error running cmd=@cmd, stdout:\n$out\nstderr:\n$err\n";
    push @outputs, [ $ofile, 'svg' ];

    my $svg64 = "$circos_dir/svg.base64";
    @cmd = ('openssl', 'base64', '-in', $ofile, '-out', $svg64);
    run_cmd(\@cmd);
    my $svg_map = `cat $circos_dir/circos.html`;
    $svg_map =~ s/ (alt|title)='\S*cId=/ $1='/g;
    $svg_map =~ s/feature&cId=fig\|/feature&cId=fig%7C/g;
    $svg_map =~ s/(<area.*href.*)>/$1 target="_blank">/g;
    $final .= $svg_map;
    $final .= '<img usemap="#circosmap" src="data:image/svg+xml;base64,'.
              `cat $svg64`; chomp($final);
    $final .= '">'."\n";

    $ofile = "$circos_dir/legend.html";
    write_output(color_legend(), $ofile);
    push @outputs, [ $ofile, 'html' ];

    $ofile = "$circos_dir/circos_final.html";
    write_output($final, $ofile);
    push @outputs, [ $ofile, 'html' ];

    return @outputs;
}

sub filename_to_genome_name {
    my ($fname) = @_;
    my $gid = basename($fname);
    $gid =~ s/\.faa$//;
    my $name = get_patric_genome_name($gid) || $gid;
    return $name;
}

sub filename_to_genome_name_with_id {
    my ($fname) = @_;
    my $gid = basename($fname);
    $gid =~ s/\.faa$//;
    my $name = get_patric_genome_name($gid) || $gid;
    $name && $gid =~ /^\d+\.\d+$/ ? "$name ($gid)" : basename($fname);
}

sub is_faa_user_genome {
    my ($fname) = @_;
    my $gid = basename($fname);
    $gid =~ s/\.faa$//;
    return $gid =~ /^\d+\.\d+$/ ? 0 : 1;
}

sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}

sub get_num_procs {
    my $n = `cat /proc/cpuinfo | grep processor | wc -l`; chomp($n);
    return $n || 8;
}

sub get_ref_type {
    my ($params) = @_;
    my $index = $params->{reference_genome_index};
    my $n1 = @{$params->{genome_ids}};
    my $n2 = @{$params->{user_genomes}};
    my $type = ($index <= $n1) ?       'genome_id'   :
               ($index <= $n1 + $n2) ? 'user_genome' :
                                       'user_feature_group';

    my $name = $params->{user_feature_groups}->[$index - $n1 - $n2 - 1] if $type eq 'user_feature_group';
    return ($type, $name);
}

sub get_genome_faa {
    my ($tmpdir, $params) = @_;
    my @genomes;
    my @tracks;
    for (@{$params->{genome_ids}}) {
        push @genomes, get_patric_genome_faa_seed($tmpdir, $_);
        push @tracks, get_patric_genome_name($_)." ($_)";
    }
    for (@{$params->{user_genomes}}) {
        my $fname = get_ws_file($tmpdir, $_);
        my $basename = basename($fname);
        push @genomes, $fname;
        push @tracks, "$basename (user fasta)";
    }
    for (@{$params->{user_feature_groups}}) {
        push @genomes, get_feature_group_faa($tmpdir, $_);
        my $group = $_; $group =~ s/.*\///;
        push @tracks, "$group (feature group)";
    }
    my $ref_i = $params->{reference_genome_index} - 1;
    if ($ref_i) {
        my $tmp = $genomes[0]; $genomes[0] = $genomes[$ref_i]; $genomes[$ref_i] = $tmp;
        my $tmp = $tracks[0]; $tracks[0] = $tracks[$ref_i]; $tracks[$ref_i] = $tmp;
    }
    # print STDERR '\@genomes = '. Dumper(\@genomes);
    # print STDERR '\@tracks = '. Dumper(\@tracks);

    return (\@genomes, \@tracks);
}

sub get_patric_genome_name {
    my ($gid) = @_;
    my $escaped = uri_escape($gid);
    my $url = "$data_api/genome/?eq(genome_id,$escaped)&select(genome_id,genome_name)&http_accept=application/json&limit(25000)";
    my $out = curl_text($url);
    my $name;
    if ($out) {
        my $ret = JSON::decode_json($out);
        $name = $ret->[0]->{genome_name};
    }
    return $name;
}

sub get_patric_genome_faa_seed {
    my ($outdir, $gid) = @_;
    my $faa = get_patric_genome_faa($gid);
    $faa =~ s/>(fig\|\d+\.\d+\.\w+\.\d+)\S+/>$1/g;
    my $ofile = "$outdir/$gid.faa";
    print "\n$ofile, $gid\n";
    open(FAA, ">$ofile") or die "Could not open $ofile";
    print FAA $faa;
    close(FAA);
    return $ofile;
}

sub get_patric_genome_faa {
    my ($gid) = @_;
    my $api_url = "$data_api/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC),eq(feature_type,CDS))&sort(+accession,+start,+end)&http_accept=application/protein+fasta&limit(25000)";
    my $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.PATRIC.faa";
    # my $url = $ftp_url;
    my $url = $api_url;
    my $out = curl_text($url);
    return $out;
}

sub get_feature_group_faa {
    my ($outdir, $group) = @_;
    my $escaped = uri_escape($group);
    my $url = "$data_api/genome_feature/?&sort(+alt_locus_tag)&select(patric_id,product,aa_sequence,genome_name,genome_id)&in(feature_id,FeatureGroup($escaped))&http_accept=application/json&limit(25000)";
    my $data = curl_json($url);
    # print STDERR Dumper($data);
    my $fg_name = $group; $fg_name =~ s/.*\///; $fg_name =~ s/\W+/\_/g;
    my $ofile = "$outdir/$fg_name.faa";
    open(FAA, ">$ofile") or die "Could not open $ofile";
    for (@$data) {
        print FAA ">$_->{patric_id}   $_->{product}   [$_->{genome_name} | $_->{genome_id}]\n";
        print FAA "$_->{aa_sequence}\n";
    }
    close(FAA);
    return $ofile;
}

sub get_feature_hash {
    my ($params) = @_;
    my %hash;
    add_feature_hash_with_genome_ids(\%hash, $params->{genome_ids});
    add_feature_hash_with_user_feature_groups(\%hash, $params->{user_feature_groups});
    return \%hash;
}

sub add_feature_hash_with_genome_ids {
    my ($hash, $gids) = @_;
    for my $gid (@$gids) {
        my $url = "$data_api/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC))&select(patric_id,accession,start,end,strand,product,refseq_locus_tag,gene)&sort(+accession,+start,+end)&http_accept=application/json&limit(25000)";
        my $json = curl_json($url);
        for my $fea (@$json) {
            my $id = $fea->{patric_id};
            $hash->{$id} = $fea;
        }
    }
}

sub add_feature_hash_with_user_feature_groups {
    my ($hash, $groups) = @_;
    for my $group (@$groups) {
        my $escaped = uri_escape($group);
        my $url = "$data_api/genome_feature/?&sort(+alt_locus_tag)&select(patric_id,accession,start,end,strand,product,refseq_locus_tag,gene)&in(feature_id,FeatureGroup($escaped))&http_accept=application/json&limit(25000)";
        my $json = curl_json($url);
        for my $fea (@$json) {
            my $id = $fea->{patric_id};
            $hash->{$id} = $fea;
        }
    }
}

sub get_genome_contigs {
    my ($gid) = @_;
    ($gid) = $gid =~ /(\d+\.\d+)/;
    my $url = "$data_api/genome_sequence/?eq(genome_id,$gid)&select(genome_name,accession,length)&sort(+accession)&http_accept=application/json&limit(25000)";
    my $json = curl_json($url);
    my @contigs = map { [ $_->{accession}, $_->{genome_name}, $_->{length} ] } @$json;
    return \@contigs;
}

sub get_feature_group_contigs {
    my ($group) = @_;
    my $escaped = uri_escape($group);
    my $url = "$data_api/genome_feature/?&sort(+alt_locus_tag)&select(genome_id,accession)&in(feature_id,FeatureGroup($escaped))&http_accept=application/json&limit(25000)";
    my $data = curl_json($url);
    my (%gids, %accs);
    for (@$data) {
        $gids{$_->{genome_id}}++;
        $accs{$_->{accession}}++;
    }
    my @contigs;
    for my $gid (keys %gids) {
        my $url = "$data_api/genome_sequence/?eq(genome_id,$gid)&select(genome_name,accession,length)&sort(+accession)&http_accept=application/json&limit(25000)";
        my $json = curl_json($url);
        push @contigs, map { [ $_->{accession}, $_->{genome_name}, $_->{length} ] } grep { $accs{$_->{accession}} } @$json;
    }
    return \@contigs;
}

sub curl_text {
    my ($url) = @_;
    my @cmd = ("curl", curl_options(), $url);
    my $cmd = join(" ", @cmd);
    $cmd =~ s/sig=[a-z0-9]*/sig=XXXX/g;
    print STDERR "$cmd\n";
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

sub patric_id_to_number {
    my ($fid) = @_;
    my ($n) = $fid =~ /peg\.(\d+)/;
    return $n;
}

sub write_output {
    my ($string, $ofile) = @_;
    open(F, ">$ofile") or die "Could not open $ofile";
    print F $string;
    close(F);
}

sub write_table {
    my ($rows, $ofile) = @_;
    open(F, ">$ofile") or die "Could not open $ofile";
    print F map { join("\t", @$_)."\n" } @$rows;
    close(F);
    print STDERR "Wrote table to $ofile\n";
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
    $id or die "Missing workspace id\n";

    my $ws = get_ws();
    my $token = get_token();

    my $base = basename($id);
    #
    # Blast tools do not like spaces in filenames.
    #
    $base =~ s/\s/_/g;
    my $file = "$tmpdir/$base";
    my $fh;
    open($fh, ">", $file) or die "Cannot open $file for writing: $!";

    print STDERR "GET WS => $tmpdir $base $id\n";
    # system("ls", "-la", $tmpdir);

    eval {
	$ws->copy_files_to_handles(1, $token, [[$id, $fh]]);
    };
    if ($@)
    {
	die "ERROR getting file $id\n$@\n";
    }
    close($fh);
    print STDERR "$id $file:\n";
    # system("ls -la $tmpdir");

    return $file;
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

sub min {
    my ($x, $y) = @_;
    return $x < $y ? $x : $y;
}

sub prepare_circos_configs {
    my ($dir, $opts) = @_;

    $opts->{radius} ||= 450;
    $opts->{$_} = "$dir/$_.conf" for qw(housekeeping ticks image ideogram colors plots circos);

    write_output(circos_ticks_config(),        $opts->{ticks});
    write_output(circos_housekeeping_config(), $opts->{housekeeping});
    write_output(circos_ideogram_config(),     $opts->{ideogram});
    write_output(circos_colors_config(),       $opts->{colors});
    write_output(circos_image_config($opts),   $opts->{image});
    write_output(circos_plot_config($opts),    $opts->{plots});
    write_output(circos_config($opts),         $opts->{circos});

    return $opts->{circos};
}

sub circos_housekeeping_config {
    return <<end_of_housekeeping

# Maximum number of image and data elements. If these are exceeded,
# Circos will quit with an error. These values are arbitrary, but in
# my experience images with significantly more data points than this
# are uninterpretable.

max_ticks*            = 5000
max_ideograms*        = 2000
max_links*            = 25000
max_points_per_track* = 25000

end_of_housekeeping
}

sub circos_ticks_config {
    return <<end_of_ticks

show_ticks       = yes
show_tick_labels = yes

<ticks>

radius    = 1.0r
color     = black
thickness = 1p

# the tick label is derived by multiplying the tick position
# by 'multiplier' and casting it in 'format':
# # sprintf(format,position*multiplier)

multiplier       = 1e-6

# %d   - integer
# %f   - float
# %.1f - float with one decimal
# %.2f - float with two decimals
# # for other formats, see http://perldoc.perl.org/functions/sprintf.html

format           = %.2f

<tick>
# major tick marks
spacing        = 100u
size           = 6p
show_label     = yes
label_size     = 9p
label_offset   = 2p
label_font     = bold
format         = %.1f
color          = black
</tick>

<tick>
# labeled minor tick marks
# spacing        = 20u
spacing        = 50u
size           = 3.5p
# show_label     = yes
show_label     = no
label_size     = 6p
label_offset   = 2p
format         = %.2f
color          = dgrey
</tick>

<tick>
# unlabeled minor tick marks
# spacing        = 5u
spacing        = 10u
size           = 2p
show_label     = no
color          = lgrey
</tick>

</ticks>

end_of_ticks
}

sub circos_image_config {
    my ($opts) = @_;
    my $radius = $opts->{radius} || 450;
    $radius .= 'p';

    return <<"end_of_image"

background = white

# dir   = .
file  = circos.svg
png   = no
svg   = yes
# radius of inscribed circle in image
radius         = $radius

# by default angle=0 is at 3 o'clock position
angle_offset      = -90

#angle_orientation = counterclockwise

auto_alpha_colors = yes
auto_alpha_steps  = 5

image_map_use      = yes
image_map_name     = circosmap
image_map_missing_parameter = removeurl

end_of_image
}

sub circos_ideogram_config {
    return <<end_of_ideogram

<ideogram>

<spacing>
default = 0.005r
</spacing>

radius    = 0.85r
thickness = 1p
fill      = yes

stroke_thickness = 0
stroke_color     = black
fill_color       = black

show_label       = yes
label_font       = default
# label_radius   = (dims(ideogram,radius_outer)+dims(ideogram,radius_inner))/2
# label_radius   = 1.08r
label_radius     = dims(ideogram,radius_outer) + 35p
label_center     = yes
label_size       = 12
label_parallel   = yes
label_color      = grey

</ideogram>

end_of_ideogram
}

sub circos_config {
    my ($opts) = @_;

    my $karyotype    = $opts->{karyotype}    || 'karyotype.txt';
    my $housekeeping = $opts->{housekeeping} || 'housekeeping.conf';
    my $ideogram     = $opts->{ideogram}     || 'ideogram.conf';
    my $ticks        = $opts->{ticks}        || 'ticks.conf';
    my $plots        = $opts->{plots}        || 'plots.conf';
    my $image        = $opts->{image}        || 'image.conf';
    my $colors       = $opts->{colors}       || 'colors.conf';

    return <<"end_of_circos"

karyotype=$karyotype

chromosomes_order_by_karyotype = yes
chromosomes_units              = 1000
chromosomes_display_default    = yes

<<include $ideogram>>
<<include $ticks>>
<<include $plots>>
<<include $colors>>

<image>
<<include $image>>
</image>

# includes etc/colors.conf
#          etc/fonts.conf
#          etc/patterns.conf
<<include etc/colors_fonts_patterns.conf>>

# system and debug settings
<<include etc/housekeeping.conf>>
<<include $housekeeping>>

anti_aliasing* = no

end_of_circos
}

sub circos_plot_config {
    my ($opts) = @_;

    my $radius = $opts->{radius} || 500;
    my $large_tiles = $opts->{large_tiles} || 'large.tiles.txt';
    print STDERR 'circos_opts = '. Dumper($opts);

    my $outer = 0.95;
    my $inner = 0.50;
    my $gap   = 0.026;
    my $maxsize = 30;

    my $n = @{$opts->{comp_genomes}} + 1;
    my $fract = sprintf("%.3f", ($outer-$inner) / $n - $gap);
    my $size = sprintf("%.1f", $radius * $fract);
    if ($size > $maxsize) {
        $size = $maxsize;
        $fract = sprintf("%.3f", $size / $radius);
    }

    my @plots;
    push @plots, circos_plot_block($large_tiles, 1, { size => 15, color => 'vdblue', stroke_color => 'vdblue' });

    my @files = ($opts->{ref_genome}, @{$opts->{comp_genomes}});
    my $r = $outer;
    my $index = 0;
    for my $f (@files) {
        if ($f eq $opts->{ref_genome}) {
            if ($opts->{ref_type} eq 'user_genome') {
                push @plots, circos_plot_block($f, $r, { size => $size, color => 'bbh_100', stroke_color => 'bbh_100' });
            } else {
                push @plots, circos_plot_block($f, $r, { size => $size, color => 'bbh_100', stroke_color => 'bbh_100', url => patric_url() });
            }
        } elsif ($opts->{is_user_genome}->{$index}) {
            push @plots, circos_plot_block($f, $r, { size => $size, rules => color_rules() });
        } else {
            push @plots, circos_plot_block($f, $r, { size => $size, rules => color_rules(), url => patric_url() });
        }
        $r = sprintf("%.3f", $r - $fract - $gap);
        $index++;
    }

    return join("\n", '<plots>', @plots, '</plots>');
}

sub patric_url {
    return '/portal/portal/patric/Feature?cType=feature&cId=[id]';
}

sub circos_plot_block {
    my ($file, $outer, $opts) = @_;

    my ($r0, $r1);
    my $size = $opts->{size} || 25;

    if ($outer) {
        $r0 = $outer.'r-'.$size.'p';
        $r1 = $outer.'r';
    }

    $r0 ||= $opts->{$r0};
    $r1 ||= $opts->{$r1};

    # see definition of tracks, tiles, margin, etc defined here:
    # http://circos.ca/documentation/tutorials/2d_tracks/tiles/images

    my $thickness        = $opts->{thickness}        || $size;
    my $show             = $opts->{show}             || 'yes';
    my $type             = $opts->{type}             || 'tile';
    my $orientation      = $opts->{orientation}      || 'in';
    my $stroke_color     = $opts->{stroke_color}     || 'green';
    my $color            = $opts->{color}            || 'green';
    my $margin           = $opts->{margin}           || '0.02';
    my $layers           = $opts->{layers}           || 1;
    my $padding          = $opts->{padding}          || 1;
    my $stroke_thickness = $opts->{stroke_thickness} || 0.1;
    my $url              = $opts->{url};
    my $rules            = $opts->{rules};

    $margin    .= 'u'   if $margin =~ /\d$/;
    $thickness .= 'p'   if $thickness =~ /\d$/;
    $url = "url = $url" if $url;

    return <<"end_of_plot_block"
    <plot>
        show = $show
        type = $type
        file = $file
        layers = $layers
        margin = $margin

        thickness = $thickness
        padding = $padding
        orientation = $orientation

        stroke_thickness = $stroke_thickness
        stroke_color = $stroke_color
        color = $color

        r0 = $r0
        r1 = $r1

        $url

        $rules

    </plot>
end_of_plot_block

}

sub circos_colors_config {
    my ($bbh, $ubh) = color_tables();
    my @colors;
    for (@$bbh) {
        my ($htmlhex, $thresh) = @$_;
        my $rgb = htmlhex2rgb($htmlhex);
        push @colors, "bbh_$thresh = ". join(",", @$rgb);
    }
    for (@$ubh) {
        my ($htmlhex, $thresh) = @$_;
        my $rgb = htmlhex2rgb($htmlhex);
        push @colors, "ubh_$thresh = ". join(",", @$rgb);
    }
    return join("\n", '<colors>', @colors, "</colors>\n");
}

sub color_rules {
    my ($bbh, $ubh) = color_tables();
    my @rules;
    for (@$bbh) {
        my ($rgb, $ident) = @$_;
        push @rules, <<"end_of_bbh_rule"
            <rule>
                condition    = var(value) >= $ident
                color        = bbh_$ident
                stroke_color = bbh_$ident
            </rule>
end_of_bbh_rule
    }
    for (@$ubh) {
        my ($rgb, $ident) = @$_;
        push @rules, <<"end_of_ubh_rule"
            <rule>
                condition    = var(value) <= -$ident
                color        = ubh_$ident
                stroke_color = ubh_$ident
            </rule>
end_of_ubh_rule
    }
    return join("\n", '<rules>', @rules, "</rules>\n");
}

sub htmlhex2rgb {
    local $_ = $_[0] || '';
    my @hex_rgb = m/^#?([\da-f][\da-f])([\da-f][\da-f])([\da-f][\da-f])$/i ? ( $1, $2, $3 )
                : m/^#?([\da-f])([\da-f])([\da-f])$/i                      ? map { "$_$_" } ( $1, $2, $3 )
                :                                                            ( '00', '00', '00' );

    return [ map { hex($_) } @hex_rgb ];
}

sub color_tables {
    my @bbh = ( [ "#9999ff", 100  ], # Bidirectional best hit
                [ "#99c2ff", 99.9 ],
                [ "#99daff", 99.8 ],
                [ "#99fffc", 99.5 ],
                [ "#99ffd8", 99   ],
                [ "#99ffb1", 98   ],
                [ "#b5ff99", 95   ],
                [ "#deff99", 90   ],
                [ "#fff899", 80   ],
                [ "#ffe099", 70   ],
                [ "#ffcf99", 60   ],
                [ "#ffc299", 50   ],
                [ "#ffb799", 40   ],
                [ "#ffae99", 30   ],
                [ "#ffa699", 20   ],
                [ "#ff9f99", 10   ] );

    my @ubh = ( [ "#ccccff", 100  ], # Unidirectional best hit
                [ "#cce1ff", 99.9 ],
                [ "#ccedff", 99.8 ],
                [ "#ccfffe", 99.5 ],
                [ "#ccffec", 99   ],
                [ "#ccffd8", 98   ],
                [ "#daffcc", 95   ],
                [ "#efffcc", 90   ],
                [ "#fffccc", 80   ],
                [ "#fff0cc", 70   ],
                [ "#ffe7cc", 60   ],
                [ "#ffe1cc", 50   ],
                [ "#ffdbcc", 40   ],
                [ "#ffd7cc", 30   ],
                [ "#ffd3cc", 20   ],
                [ "#ffcfcc", 10   ] );

    return (\@bbh, \@ubh);
}

sub color_legend {
  return qq~<TABLE style="cellspacing:1px">
<TR><TD>&nbsp;</TD>
    <TD Align=center ColSpan=16>Percent protein sequence identity</TD>
</TR>
<TR><TD style="width:180px">Bidirectional best hit</TD>
    <TD style="align:center;width:25px;background:#9999ff">100</TD>
    <TD style="align:center;width:25px;background:#99c2ff">99.9</TD>
    <TD style="align:center;width:25px;background:#99daff">99.8</TD>
    <TD style="align:center;width:25px;background:#99fffc">99.5</TD>
    <TD style="align:center;width:25px;background:#99ffd8">99</TD>
    <TD style="align:center;width:25px;background:#99ffb1">98</TD>
    <TD style="align:center;width:25px;background:#b5ff99">95</TD>
    <TD style="align:center;width:25px;background:#deff99">90</TD>
    <TD style="align:center;width:25px;background:#fff899">80</TD>
    <TD style="align:center;width:25px;background:#ffe099">70</TD>
    <TD style="align:center;width:25px;background:#ffcf99">60</TD>
    <TD style="align:center;width:25px;background:#ffc299">50</TD>
    <TD style="align:center;width:25px;background:#ffb799">40</TD>
    <TD style="align:center;width:25px;background:#ffae99">30</TD>
    <TD style="align:center;width:25px;background:#ffa699">20</TD>
    <TD style="align:center;width:25px;background:#ff9f99">10</TD>
</TR>
<TR><TD style="width:180px">Unidirectional best hit</TD>
    <TD style="align:center;width:25px;background:#ccccff">100</TD>
    <TD style="align:center;width:25px;background:#cce1ff">99.9</TD>
    <TD style="align:center;width:25px;background:#ccedff">99.8</TD>
    <TD style="align:center;width:25px;background:#ccfffe">99.5</TD>
    <TD style="align:center;width:25px;background:#ccffec">99</TD>
    <TD style="align:center;width:25px;background:#ccffd8">98</TD>
    <TD style="align:center;width:25px;background:#daffcc">95</TD>
    <TD style="align:center;width:25px;background:#efffcc">90</TD>
    <TD style="align:center;width:25px;background:#fffccc">80</TD>
    <TD style="align:center;width:25px;background:#fff0cc">70</TD>
    <TD style="align:center;width:25px;background:#ffe7cc">60</TD>
    <TD style="align:center;width:25px;background:#ffe1cc">50</TD>
    <TD style="align:center;width:25px;background:#ffdbcc">40</TD>
    <TD style="align:center;width:25px;background:#ffd7cc">30</TD>
    <TD style="align:center;width:25px;background:#ffd3cc">20</TD>
    <TD style="align:center;width:25px;background:#ffcfcc">10</TD>
</TR>
</TABLE>~;
}

sub track_legend {
    my ($tracks) = @_;

    my @html = ("</br>List of tracks, from outside to inside:</br>", '<ol type="1">');
    push @html, "  <li>$_</li>" for @$tracks;
    push @html, "</ol>";
    return join("\n", @html)."\n";
}
