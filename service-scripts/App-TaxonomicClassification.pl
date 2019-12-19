#
# App wrapper for taxonomic classification.
# Initial version that does not internally fork and report output; instead
# is designed to be executed by p3x-app-shepherd.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;
use Bio::KBase::AppService::AppConfig qw(metagenome_dbs);
use Bio::KBase::AppService::TaxonomicClassificationReport;
use IPC::Run;
use Cwd;
use File::Path 'make_path';
use strict;
use Data::Dumper;
use File::Basename;
use File::Temp;
use JSON::XS;
use Getopt::Long::Descriptive;

my $app = Bio::KBase::AppService::AppScript->new(\&run_classification, \&preflight);

$app->run(\@ARGV);

sub run_classification
{
    my($app, $app_def, $raw_params, $params) = @_;
    
    #
    # Set up options for tool and database.
    #
    
    my @cmd;
    my @options;
    
    if ($params->{algorithm} ne 'Kraken2')
    {
	die "Only Kraken2 is supported currently";
    }
    
    my %db_map = ('Kraken2' => 'kraken2',
		  Greengenes => 'Greengenes',
		  RDP => 'RDP',
		  SILVA => 'SILVA');
    my $db_dir = $db_map{$params->{database}};
    if (!$db_dir)
    {
	die "Invalid database name '$params->{database}' specified. Valid values are " . join(", ", map { qq("$_") } keys %db_map);
    }
    
    my $db_path = metagenome_dbs . "/$db_dir";
    
    @cmd = ("kraken2");
    push(@options, "--db", $db_path);
    push(@options, "--memory-mapping");
    
    #
    # If we are running under Slurm, pick up our memory and CPU limits.
    #
    my $mem = $ENV{P3_ALLOCATED_MEMORY};
    my $cpu = $ENV{P3_ALLOCATED_CPU};
    
    if ($cpu)
    {
	push(@options, "--threads", $cpu);
    }
    
    #
    # Stage input.
    #
    # We process input differently for contigs vs reads.
    #
    
    
    if ($params->{input_type} eq 'reads')
    {
	process_read_input($app, $params, \@cmd, \@options);
    }
    elsif ($params->{input_type} eq 'contigs')
    {
	process_contig_input($app, $params, \@cmd, \@options);
    }
    else
    {
	die "Invalid input type '$params->{input_type}'";
    }
}

sub process_read_input
{
    my($app, $params, $cmd, $options) = @_;

    my @cmd = @$cmd;
    my @options = @$options;
    
    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params, 1);
    
    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);
    
    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    
    my $top = getcwd;
    my $staging = "$top/staging";
    my $output = "$top/output";
    make_path($staging, $output);
    $readset->localize_libraries($staging);
    $readset->stage_in($app->workspace);

    my @paths;
    # this should autodetect
    # push(@options, "--fastq-input");
    my $pe_only = 1;

    my $pe_cb = sub {
	my($lib) = @_;
	push @paths, $lib->paths();
    };
    my $se_cb = sub {
	my($lib) = @_;
	push @paths, $lib->paths();
	$pe_only = 0;
    };

    #
    # We skip SRRs since the localize/stage_in created PE and SE libs for them.
    #
    $readset->visit_libraries($pe_cb, $se_cb, undef);
    print Dumper(\@options, \@paths);

    if ($pe_only)
    {
	push(@options, "--paired");
    }

    # ugh.
    
    my $save_classified = $params->{save_classified_sequences};
    $save_classified = 0 if $save_classified eq 'false';
    
    my $save_unclassified = $params->{save_unclassified_sequences};
    $save_unclassified = 0 if $save_unclassified eq 'false';
    
    if ($pe_only)
    {
	push(@options, "--classified-out", "$output/classified#.fastq") if $save_classified;
	push(@options, "--unclassified-out", "$output/unclassified#.fastq") if $save_unclassified;
    }
    else
    {
	push(@options, "--classified-out", "$output/classified.fastq") if $save_classified;
	push(@options, "--unclassified-out", "$output/unclassified.fastq") if $save_unclassified;
    }

    push(@options, "--report", "$output/full_report.txt");
    push(@options, "--output", "$output/output.txt");
    push(@options, "--report-zero-counts");
    push(@options, "--use-names");

    push(@options, @paths);

    run_kraken_and_process_output($app, $params, \@cmd, \@options, $output);
}

sub process_contig_input
{
    my($app, $params, $cmd, $options) = @_;

    my @cmd = @$cmd;
    my @options = @$options;

    my $ws = $app->workspace;
    my $top = getcwd;
    my $staging = "$top/staging";
    my $output = "$top/output";
    make_path($staging, $output);

    my $contigs = $params->{contigs};
    my $base = basename($contigs);
    my $contigs_local = "$staging/$base";

    print STDERR "Stage in contigs from $contigs to $contigs_local\n";

    eval {
	$ws->download_file($contigs, $contigs_local, 1);
    };
    if ($@)
    {
	die "Error downloading contigs from $contigs to $contigs_local:\n$@";
    }


    push(@options, "--classified-out", "$output/classified.fa") if $params->{save_classified_sequences};
    push(@options, "--unclassified-out", "$output/unclassified.fa") if $params->{save_unclassified_sequences};

    push(@options, "--report", "$output/full_report.txt");
    push(@options, "--output", "$output/output.txt");
    push(@options, "--report-zero-counts");
    push(@options, "--use-names");

    push(@options, $contigs_local);

    run_kraken_and_process_output($app, $params, \@cmd, \@options, $output);
}


sub run_kraken_and_process_output
{
    my($app, $params, $cmd, $options, $output) = @_;
    
    warn "Run: @$cmd @$options\n";
    my $ok = IPC::Run::run((@$cmd, @$options), ">", "$output/kraken2.stdout", "2>", "$output/kraken2.stderr");

    my $err = $?;
    warn "Kraken returns ok=$ok err=$err\n";

    if ($ok)
    {
	#
	# Process the full report to remove zero counts to create report.txt
	#
	if (open(FULL, "<", "$output/full_report.txt"))
	{
	    if (open(REP, ">", "$output/report.txt"))
	    {
		while (<FULL>)
		{
		    my($count) = /^[^\t]+\t([^\t]+)/;
		    if ($count > 0)
		    {
			print REP $_;
		    }
		}
		close(FULL);
		close(REP);
	    }
	    else
	    {
		warn "Cannot open $output/report.txt for writing: $!";
	    }
	}
	else
	{
	    warn "Cannot open $output/full_report.txt: $!";
	}
    }

    #
    # Create the krona chart
    #
    if (-s "$output/report.txt")
    {
	my @cmd = ("ktImportTaxonomy", '-t', '5', '-m', '3', "$output/report.txt", "-o", "$output/chart.html");
	my $ok = IPC::Run::run(\@cmd,
		     '>', 'krona.out', '2>', 'krona.err');
	if (!$ok)
	{
	    warn "Error $? running @cmd\n";
	}
    }

    #
    # Compress output if large.
    #
    my $output_name = "$output/output.txt";
    if (-s "$output/output.txt" > 1_000_000)
    {
	print STDERR "Compressing $output/output.txt";
	system("gzip", "-f", "$output/output.txt");
	$output_name = "$output/output.txt.gz";
    }
    


    if (open(my $out_fh, ">", "$output/TaxonomicReport.html"))
    {
	Bio::KBase::AppService::TaxonomicClassificationReport::write_report($app->task_id, $params,
									    "$output/report.txt", $output_name, $out_fh);
	close($out_fh);
    }

    save_output_files($app, $output);

    $app->write_results(undef, $ok);
}


#
# Run preflight to estimate size and duration.
#
sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params);

    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);

    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }

    my $mem = "32G";
    #
    # Kraken DB requires a lot more memory.
    #
    if (lc($params->{database}) eq 'kraken2')
    {
	$mem = "80G";
    }
    
    my $time = 60 * 60 * 10;
    my $pf = {
	cpu => 8,
	memory => $mem,
	runtime => $time,
	storage => 1.1 * ($comp_size + $uncomp_size),
    };
    return $pf;
}

sub save_output_files
{
    my($app, $output) = @_;
    
    my %suffix_map = (fastq => 'reads',
		      txt => 'txt',
		      out => 'txt',
		      err => 'txt',
		      html => 'html');

    #
    # Make a pass over the folder and compress any fastq files.
    #
    if (opendir(D, $output))
    {
	while (my $f = readdir(D))
	{
	    my $path = "$output/$f";
	    if (-f $path &&
		($f =~ /\.fastq$/))
	    {
		my $rc = system("gzip", "-f", $path);
		if ($rc)
		{
		    warn "Error $rc compressing $path";
		}
	    }
	}
    }
    if (opendir(D, $output))
    {
	while (my $f = readdir(D))
	{
	    my $path = "$output/$f";

	    my $p2 = $f;
	    $p2 =~ s/\.gz$//;
	    my($suffix) = $p2 =~ /\.([^.]+)$/;
	    my $type = $suffix_map{$suffix} // "txt";
	    $type = "unspecified" if $f eq 'output.txt.gz';

	    if (-f $path)
	    {
		print "Save $path type=$type\n";
		my $shock = -s $path > 10000 ? 1 : 0;
		$app->workspace->save_file_to_file($path, {}, $app->result_folder . "/$f", $type, 1, $shock, $app->token->token);
	    }
	}
	    
    }
    else
    {
	warn "Cannot opendir $output: $!";
    }
}
