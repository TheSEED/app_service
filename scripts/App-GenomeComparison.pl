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

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

use bidir_best_hits;

my $script = Bio::KBase::AppService::AppScript->new(\&process_proteomes);
my $rc = $script->run(\@ARGV);
exit $rc;

# use JSON;
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

    # my $tmpdir = File::Temp->newdir();
    my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
    print "tmpdir = $tmpdir\n";

    my @genomes = get_genome_faa($tmpdir, $params);
    print STDERR '\@genomes = '. Dumper(\@genomes);

    my @outputs = run_find_bdbh($tmpdir, \@genomes, $params);

    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$filename", $type, 1,
					       (-s "$ofile" > 1000_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }
}

sub run_find_bdbh {
    my ($tmpdir, $genomes, $params) = @_;

    my $nproc = get_num_procs();

    my $exe = "find_bidir_best_hits";
    my $blastp = "blastp";

    verify_cmd($exe) and verify_cmd($blastp);

    my $opts = { min_cover     => $params->{min_seq_cov},
                 min_positives => $params->{min_positives},
                 min_ident     => $params->{min_ident},
                 max_e_val     => $params->{max_e_val},
                 program       => 'blastp',
                 blast_opts    => "-a $nproc",
                 verbose       => 1
               };

    print "BBH options: ", Dumper($opts);
    my @orgs = @$genomes;
    my @features;
    my %hits;
    my $ref = shift @orgs;
    for my $g (@orgs) {
        print "Run bidir_best_hits::bbh: ", join(" <=> ", $ref, $g)."\n";
        my ($bbh, $log1, $log2) = bidir_best_hits::bbh($ref, $g, $opts);
        if (!@features) {
            @features = map { $_->[0] } @$log1; 
            for (@$log1) {
                my ($q_id, $q_len) = @$_;
                $hits{$q_id} = [$q_id, $q_len];
            }
        }
        for (@$log1) {
            my ($q_id, $q_len, $arrow, $s_id, $s_len, $fract_id, $fract_pos, $q_coverage, $s_coverage) = @$_;
            my $type = $arrow eq '<->' ? 'bi' :
                       $arrow eq ' ->' ? 'uni' : undef;
            push @{$hits{$q_id}}, ($s_id, $type, $s_len, $fract_id, $fract_pos, $q_coverage, $s_coverage);
        }
    }
    my $ofile = "$tmpdir/genome_comparison.txt";
    open(LOG, ">$ofile") or die "Could not open $ofile";
    print LOG '##'.join(",", map { basename($_) } @$genomes)."\n";
    print LOG '##'.join(",", map { filename_to_genome_name($_) } @$genomes)."\n";
    for (@features) {
        print LOG join("\t", @{$hits{$_}})."\n";
    }
    close(LOG);
    my @outputs;
    push @outputs, [ $ofile, 'unspecified' ];
    return @outputs;
}

sub filename_to_genome_name {
    my ($fname) = @_;
    my $gid = basename($fname);
    $gid =~ s/\.faa//;
    my $name = get_patric_genome_name($gid) || $gid;
    return $name;
}

sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}

sub get_num_procs {
    # return 8;
    my $n = `cat /proc/cpuinfo | grep processor | wc -l`; chomp($n);
    return $n || 8;
}

sub get_genome_faa {
    my ($tmpdir, $params) = @_;
    my @genomes;
    for (@{$params->{genome_ids}}) {
        push @genomes, get_patric_genome($tmpdir, $_, 'faa');
    }
    for (@{$params->{user_genomes}}) {
        push @genomes, get_ws_file($tmpdir, $_);
    }
    my $ref_i = $params->{reference_genome_index} - 1;
    if ($ref_i) {
        my $tmp = $genomes[0];
        $genomes[0] = $genomes[$ref_i];
        $genomes[$ref_i] = $tmp;
    }
    return @genomes;
}

sub get_patric_genome_name {
    my ($gid) = @_;
    my $url = "http://www.alpha.patricbrc.org/api/genome/?eq(genome_id,$gid)&select(genome_id,genome_name)&http_accept=application/json";
    my $json = `curl '$url'`;
    my $name;
    if ($json) {
        my $ret = JSON::decode_json($json);
        $name = $ret->[0]->{genome_name};
    }
    return $name;
}

sub get_patric_genome {
    my ($outdir, $gid, $type) = @_;
    $type = 'faa' if $type eq 'protein';
    my $ofile = "$outdir/$gid.$type";
    my $api_type = "protein+fasta" if $type eq 'faa';
    my $api_url = "http://www.alpha.patricbrc.org/api/genome_feature/?and(eq(genome_id,$gid),eq(annotation,PATRIC))&sort(+accession,+start,+end)&http_accept=application/$api_type";
    my $ftp_url = "ftp://ftp.patricbrc.org/patric2/patric3/genomes/$gid/$gid.PATRIC.$type";
    my $url = $ftp_url;
    # my $url = $api_url;
    my @cmd = ("curl", $url);
    print join(" ", @cmd)."\n";
    run(\@cmd, ">", $ofile) or die "Error downloading file: $url\n";
    return $ofile;
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

sub run_cmd {
    my ($cmd) = @_;
    my ($out, $err);
    my $rc = run($cmd, '>', \$out, '2>', \$err);
    $rc or die "Error running cmd=@$cmd, stdout:\n$out\nstderr:\n$err\n";
    # print STDERR "STDOUT:\n$out\n";
    # print STDERR "STDERR:\n$err\n";
    return ($rc, $out, $err);
}

