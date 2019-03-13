#
# App wrapper for taxonomic classification.
# Initial version that does not internally fork and report output; instead
# is designed to be executed by p3x-app-shepherd.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;
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

my($opt, $usage) = describe_options("%c %o app-definition.json param-values.json",
				    ["preflight=s" => "Run app preflight and write results to given file."],
				    ["help|h" => "Show this help message."]);
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 2;
my $app_def_file = shift;
my $param_values_file = shift;

my $app = Bio::KBase::AppService::AppScript->new();

my $params = $app->preprocess_parameters($app_def_file, $param_values_file);
$app->initialize_workspace();

if ($opt->preflight)
{
    preflight($app, $params, $opt->preflight);
    exit 0;
}

$app->setup_folders();

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

my $db_path = "/vol/patric3/metagenome_dbs/$db_dir";

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
	push(@options, "--classified-out", "$output/classified#.fastq");
	push(@options, "--unclassified-out", "$output/unclassified#.fastq");
    }
    else
    {
	push(@options, "--classified-out", "$output/classified.fastq");
	push(@options, "--unclassified-out", "$output/unclassified.fastq");
    }

    push(@options, "--report", "$output/full_report.txt");
    push(@options, "--output", "$output/output.txt");
    push(@options, "--report-zero-counts");
    push(@options, "--use-names");

    push(@options, @paths);
    
    warn "Run: @cmd @options\n";
    my $ok = IPC::Run::run((@cmd, @options), ">", "$output/kraken2.stdout", "2>", "$output/kraken2.stderr");

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
    if (open(my $out_fh, ">", "$output/TaxonomicReport.html"))
    {
	Bio::KBase::AppService::TaxonomicClassificationReport::write_report($app->task_id, $params, "$output/report.txt", $out_fh);
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
    my($app, $params, $preflight_out) = @_;

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params);

    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);

    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => 360,
	storage => 1.1 * ($comp_size + $uncomp_size),
    };
    open(PF, ">", $preflight_out) or die "Cannot write preflight file $preflight_out: $!";
    my $js = JSON::XS->new->pretty(1)->encode($pf);
    print PF $js;
    close(PF);
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
		($f =~ /\.fastq$/ || $f eq 'output.txt'))
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

	    if (-f $path)
	    {
		print "Save $path type=$type\n";
		$app->workspace->save_file_to_file($path, {}, $app->result_folder . "/$f", $type, 1, 0, $app->token->token);
	    }
	}
	    
    }
    else
    {
	warn "Cannot opendir $output: $!";
    }
}
