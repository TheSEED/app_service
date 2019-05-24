#
# App wrapper for read mapping
# Initial version that does not internally fork and report output; instead
# is designed to be executed by p3x-app-shepherd.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ReadSet;
use Bio::KBase::AppService::MetagenomicReadMappingReport 'write_report';
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

my $app = Bio::KBase::AppService::AppScript->new(\&run_mapping, \&preflight);

my $rc = $app->run(\@ARGV);

exit $rc;

sub run_mapping
{
    my($self, $app, $app_def, $raw_params, $params) = @_;

    print STDERR "Processed parameters for application " . $app->app_definition->{id} . ": ", Dumper($params);

    my $here = getcwd;
    my $staging_dir = "$here/staging";
    my $output_dir = "$here/output";
    
    eval {
	make_path($staging_dir, $output_dir);
	run($app, $params, $staging_dir, $output_dir);
    };
    my $err = $@;
    if ($err)
    {
	warn "Run failed: $@";
    }
    
    save_output_files($app, $output_dir);
}

sub run
{
    my($app, $params, $staging_dir, $output_dir) = @_;

    #
    # Set up options for tool and database.
    #
    
    my @cmd;
    
    if ($params->{gene_set_type} ne 'predefined_list')
    {
	die "Gene set type $params->{gene_set_type} not supported";
    }
    
    my %db_map = (CARD => 'CARD',
		  VFDB => 'VFDB');
    
    my $db_dir = $db_map{$params->{gene_set_name}};
    if (!$db_dir)
    {
	die "Invalid gene set name '$params->{gene_set_name}' specified. Valid values are " . join(", ", map { qq("$_") } keys %db_map);
    }
    
    my $db_path = "/vol/patric3/kma_db/$db_dir";

    my $kma_identity = 70;

    -f "$db_path.name" or die "Database file for $db_path not found\n";

    my @input_params = stage_input($app, $params, $staging_dir);
    my $output_base = "$output_dir/kma";
    @cmd = ("kma");
    push(@cmd,
	 "-ID", $kma_identity,
	 "-t_db", $db_path,
	 @input_params,
	 "-o", $output_base);
    
    #
    # If we are running under Slurm, pick up our memory and CPU limits.
    #
    my $mem = $ENV{P3_ALLOCATED_MEMORY};
    my $cpu = $ENV{P3_ALLOCATED_CPU};

    print STDERR "Run: @cmd\n";
    my $ok = IPC::Run::run(\@cmd);
    if (!$ok)
    {
	die "KMA execution failed with $?: @cmd";
    }

    #
    # Write our report.
    #
    
    if (open(my $out_fh, ">", "$output_dir/MetagenomicReadMappingReport.html"))
    {
    	write_report($app->task_id, $params, $output_base, $out_fh);
    	close($out_fh);
    }
}

#
# Stage input data. Return the input parameters for kma.
#
sub stage_input
{
    my($app, $params, $staging_dir) = @_;

    my $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params, 1);
    
    my($ok, $errs, $comp_size, $uncomp_size) = $readset->validate($app->workspace);
    
    if (!$ok)
    {
	die "Readset failed to validate. Errors:\n\t" . join("\n\t", @$errs);
    }
    
    $readset->localize_libraries($staging_dir);
    $readset->stage_in($app->workspace);

    my @app_params;

    my $pe_cb = sub {
	my($lib) = @_;
	push(@app_params, "-ipe", $lib->paths());
    };
    my $se_cb = sub {
	my($lib) = @_;
	push(@app_params, "-i", $lib->paths());
    };

    #
    # We skip SRRs since the localize/stage_in created PE and SE libs for them.
    #
    $readset->visit_libraries($pe_cb, $se_cb, undef);

    return @app_params;
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

    my $time = 60 * 60 * 12;
    my $pf = {
	cpu => 1,
	memory => "32G",
	runtime => $time,
	storage => 1.1 * ($comp_size + $uncomp_size),
    };

    return $pf;
}

sub save_output_files
{
    my($app, $output) = @_;
    
    my %suffix_map = (fastq => 'reads',
		      fss => 'feature_dna_fasta',
		      res => 'txt',
		      aln => 'txt',
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
