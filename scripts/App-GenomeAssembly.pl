#
# The Genome Assembly application.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';
use POSIX;

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

my $ar_run = "ar-run";
my $ar_get = "ar-get";
my $ar_filter = "ar-filter";
my $ar_stat = "ar-stat";
# my $fastq_dump = "fastq-dump";
my $fastq_dump = "/home/fangfang/programs/sratoolkit.2.8.2-1-ubuntu64/bin/fastq-dump";

my $script = Bio::KBase::AppService::AppScript->new(\&process_reads);

my @large_files;

my $rc = $script->run(\@ARGV);

exit $rc;

our $global_ws;
our $global_token;

sub process_reads {
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    $global_token = $app->token();
    $global_ws = $app->workspace;

    verify_cmd($ar_run) and verify_cmd($ar_get) and verify_cmd($ar_filter);

    my $output_folder = $app->result_folder();
    # my $output_base   = $params->{output_file};
    my $output_name   = "contigs";

    my $recipe = $params->{recipe};
    my @method = ("-r", $recipe) if $recipe;

    my $pipeline = $params->{pipeline};
    print "PIPELINE: $pipeline\n";

    @method = ("-p", parse_pipeline_args($pipeline)) if $pipeline;

    my $tmpdir = File::Temp->newdir();
    # my $tmpdir = File::Temp->newdir( CLEANUP => 0 );

    my @ai_params = parse_input($tmpdir, $params);

    if (@large_files)
    {
	print STDERR "Enabling curl due to large files:\n";
	print "\t$_->[0] $_->[1]\n" foreach @large_files;
	push(@ai_params, "--curl");
    }

    my $out_tmp = "$tmpdir/$output_name";

    my $token = get_token();

    $ENV{ARAST_AUTH_TOKEN} = $token->token;
    $ENV{ARAST_AUTH_USER}  = $token->user_id;

    my @submit_cmd = ($ar_run, @method, @ai_params);
    print STDERR '\@submit_cmd = '. Dumper(\@submit_cmd);

    my $filter_len = $params->{min_contig_len} || 300;
    my $filter_cov = $params->{min_contig_cov} || 5;

    my @get_cmd = ($ar_get, '-w', '-p');
    my @filter_cmd = ($ar_filter, '-l', $filter_len, '-c', $filter_cov); # > $out_tmp";

    my $submit_out;
    my $submit_err;
    print STDERR "Running @submit_cmd\n";
    my $submit_ok = run(\@submit_cmd, '>', \$submit_out, '2>', \$submit_err);
    $submit_ok or die "Error submitting run. Run command=@submit_cmd, stdout:\n$submit_out\nstderr:\n$submit_err\n";

    print STDERR "Submission returns\n$submit_out\n";
    my($arast_job) = $submit_out =~ /job\s+id:\s+(\d+)/i;

    print STDERR "Submitted job $arast_job, waiting for results\n";
    print STDERR `$ar_stat`;

    #
    # Poll job status once per minute. Every 10 minutes or when the job status changes,
    # emit the status.
    #

    my $start = time;
    my $last_report;
    my $last_status;
    my $finish_status;
    print STDERR strftime("%Y-%m-%d %H:%M:%S", localtime $start) . ": job $arast_job starting\n";
    while (1)
    {
	my $now = time;
	my $status;
	my @stat = ($ar_stat, "-j", $arast_job);
	my $stat_ok = run(\@stat, ">", \$status);

	if (!$stat_ok)
	{
	    die "Error running status command @stat: $!";
	}
	if ($status eq '')
	{
	    die "Status command @stat did not return output";
	}

	chomp $status;
	if ($status ne $last_status || ($now - $last_report > 600))
	{
	    print STDERR strftime("%Y-%m-%d %H:%M:%S", localtime $now) . ": job $arast_job status: $status\n";
	    $last_report = $now;
	    $last_status = $status
	}

	if ($status =~ /complete|fail/i)
	{
	    print STDERR strftime("%Y-%m-%d %H:%M:%S", localtime $now) . ": job $arast_job has complete status: $status\n";
	    $finish_status = $status;
	    last;
	}
	sleep 60;
    }

    if ($finish_status =~ /error|fail/i)
    {
	print STDERR "Job $arast_job finished with error status: $finish_status\n";
	my $report;
	my $ok = run([$ar_get, "-l", "-j", $arast_job], ">", \$report);
	$ok or warn "Error retrieving assembly job log: $!";
	print STDERR "\nAssembly job log for failed job $arast_job:\n$report\n";
	die "Assembly failed";
    }

    print STDERR "Running pull: @get_cmd -j $arast_job | @filter_cmd\n";
    my $pull_ok = run([@get_cmd, "-j", $arast_job], "|",
		      \@filter_cmd, '>', $out_tmp);
    $pull_ok or die "Error retrieving results from job $arast_job\n";

    my $download_ok = run([$ar_get, "-j", $arast_job, "-o", $tmpdir]);
    $download_ok or die "Error downloading results from $arast_job\n";

    my @outputs;

    my $analysis_dir = "$arast_job\_analysis";
    system("cd $tmpdir && zip -r $arast_job\_analysis.zip $analysis_dir");
    push @outputs, ["$tmpdir/$arast_job\_analysis.zip", 'zip'] if -s "$tmpdir/$arast_job\_analysis.zip";

    my ($report) = glob("$tmpdir/$arast_job*report.txt");
    if ($report) {
        system("mv $report $tmpdir/report.txt");
        push @outputs, ["$tmpdir/report.txt", 'txt'];
    }

    my @assemblies = glob("$tmpdir/$arast_job*.fa $tmpdir/$arast_job*.fasta");
    push @outputs, [ $_, 'contigs' ] for @assemblies;

    system("mv $out_tmp $out_tmp.fa");
    push @outputs, ["$out_tmp.fa", 'contigs'];

    for (@outputs) {
	my ($ofile, $type) = @$_;
	if (-f "$ofile") {
            my $filename = basename($ofile);
            print STDERR "Output folder = $output_folder\n";
            print STDERR "Saving $ofile => $output_folder/$filename ...\n";
	    $app->workspace->save_file_to_file("$ofile", {}, "$output_folder/$filename", $type, 1,
					       (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

    # my $ws = get_ws();
    # my $meta;

    # my $result_folder = $app->result_folder();
    # $ws->save_file_to_file("$out_tmp", $meta, "$result_folder/$output_name", 'contigs',
    #                        1, 1, $token);

    undef $global_ws;
    undef $global_token;

    return { arast_job_id => $arast_job };
}

sub parse_pipeline_args {
    my ($pipe) = @_;

    my @chars = split('', $pipe);

    my $qc;        # flag:  in any quotes
    my ($qs, $qd); # flags: in double and single quotes
    my ($beg, $len) = (0, 0);
    my @args;
    for my $c (@chars) {
        $qs = !$qs if $c eq "'";
        $qd = !$qd if $c eq '"';
        if (!$qc && $qs+$qd) {  # entering quotes
            my $arg = clean_arg(substr($pipe, $beg, $len));
            $beg += $len;
            $len = 0;
            push @args, split(/\s+/, $arg) if $arg;
        } elsif ($qc && !($qs+$qd)) { # exiting quotes
            my $arg = clean_arg(substr($pipe, $beg, $len+1));
            $beg += $len+1;
            $len = -1;
            push @args, $arg if $arg;
        }
        $qc = $qs + $qd;
        $len++;
    }

    my $arg = clean_arg(substr($pipe, $beg, $len));
    push @args, split(/\s+/, $arg) if $arg;

    return @args;
}

sub clean_arg {
    my ($arg) = @_;
    return $1 if $arg =~ /^\s*"(.*)"\s*$/;
    return $1 if $arg =~ /^\s*'(.*)'\s*$/;
    $arg =~ s/^\s+//;
    $arg =~ s/\s+$//;
    $arg;
}

sub get_srr_lib {
    my ($tmpdir, $id) = @_;
    verify_cmd($fastq_dump);
    print "$tmpdir $id\n";

    # see https://edwards.sdsu.edu/research/fastq-dump/
    # we do not use '--readids' because error correction in SPAdes requires paired end reads to have the same ID
    my @cmd = ($fastq_dump, '--outdir', $tmpdir, '--split-3', '--dumpbase', # '--gzip',
               '--clip', '--skip-technical', '--read-filter', 'pass', $id);

    my ($run_out, $run_err, $run_ok);
    print STDERR "Running @cmd\n";
    my $run_ok = run(\@cmd, '>', \$run_out, '2>', \$run_err);
    $run_ok or die "Error downloading SRR data. Command=@cmd, stdout:\n$run_out\nstderr:\n$run_err\n";

    my $lib;
    my ($read1, $read2, $read) = map { "$tmpdir/$id\_pass$_.fastq" } ("_1", "_2", "");

    $lib->{read1} = $read1 if -s $read1;
    $lib->{read2} = $read2 if -s $read2;
    $lib->{read}  = $read  if -s $read;  # unpaired reads

    return $lib;
}

sub get_ws {
    return $global_ws;
}

sub get_token {
    return $global_token;
}

my $global_file_count;
sub get_ws_file {
    my ($tmpdir, $id) = @_;
    # return $id;
    my $ws = get_ws();
    my $token = get_token();

    my $base = basename($id);
    my $file = "$tmpdir/$base";
    $file =~ s/\s/_/g;
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
    if (-s $file == 0)
    {
	die "Zero length download for file $file from $id\n";
    }
    #
    # Hack hack. Set a flag if any input file is >= 3GB.
    #
    if (-s $file > 3_000_000_000)
    {
	push(@large_files, [$file, -s $file]);
    }
    print "$id $file:\n";
    system("ls -la $tmpdir");

    return $file;
}

sub parse_input {
    my ($tmpdir, $input) = @_;

    my @params;

    my ($pes, $ses, $srr, $ref) = ($input->{paired_end_libs},
                                   $input->{single_end_libs},
                                   $input->{srr_ids},
                                   $input->{reference_assembly});

    for (@$pes) { push @params, parse_pe_lib($tmpdir, $_) }
    for (@$ses) { push @params, parse_se_lib($tmpdir, $_) }
    for (@$srr) { push @params, parse_srr_id($tmpdir, $_) }
    push @params, parse_ref($tmpdir, $ref) if $ref;

    return @params;
}

sub parse_pe_lib {
    my ($tmpdir, $lib) = @_;
    my @params;
    push @params, "--pair";
    push @params, get_ws_file($tmpdir, $lib->{read1});
    push @params, get_ws_file($tmpdir, $lib->{read2}) if $lib->{read2};
    my @ks = qw(platform insert_size_mean insert_size_std_dev read_orientation_outward interleaved);
    for my $k (@ks) {
        push @params, $k."=".$lib->{$k} if $lib->{$k};
    }
    return @params;
}

sub parse_se_lib {
    my ($tmpdir, $lib) = @_;
    my @params;
    push @params, "--single";
    push @params, get_ws_file($tmpdir, $lib->{read});
    my @ks = qw(platform);
    for my $k (@ks) {
        push @params, $k."=".$lib->{$k} if $lib->{$k};
    }
    return @params;
}

sub parse_ref {
    my ($tmpdir, $ref) = @_;
    my @params;
    push @params, "--reference";
    push @params, get_ws_file($tmpdir, $ref);
    return @params;
}

sub parse_srr_id {
    my ($tmpdir, $id) = @_;
    my @params;
    my $lib = get_srr_lib($tmpdir, $id);
    my @params;
    if ($lib->{read1} && $lib->{read2}) {
        push @params, "--pair";
        push @params, $lib->{read1};
        push @params, $lib->{read2};
    }   # unpaired reads are a result of read filtering; ignore them when paired reads are found
    elsif ($lib->{read}) {
        push @params, "--single";
        push @params, $lib->{read};
    }
    return @params;
}

sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}

#-----------------------------------------------------------------------------
#  Read the entire contents of a file or stream into a string.  This command
#  if similar to $string = join( '', <FH> ), but reads the input by blocks.
#
#     $string = slurp_input( )                 # \*STDIN
#     $string = slurp_input(  $filename )
#     $string = slurp_input( \*FILEHANDLE )
#
#-----------------------------------------------------------------------------
sub slurp_input
{
    my $file = shift;
    my ( $fh, $close );
    if ( ref $file eq 'GLOB' )
    {
        $fh = $file;
    }
    elsif ( $file )
    {
        if    ( -f $file )                    { $file = "<$file" }
        elsif ( $_[0] =~ /^<(.*)$/ && -f $1 ) { }  # Explicit read
        else                                  { return undef }
        open $fh, $file or return undef;
        $close = 1;
    }
    else
    {
        $fh = \*STDIN;
    }

    my $out =      '';
    my $inc = 1048576;
    my $end =       0;
    my $read;
    while ( $read = read( $fh, $out, $inc, $end ) ) { $end += $read }
    close $fh if $close;

    $out;
}
