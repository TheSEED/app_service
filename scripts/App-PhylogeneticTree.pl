use strict;
use P3DataAPI;

use Data::Dumper;
use IPC::Run 'run';

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

my $max_processes = 8;

my $data_api_url = Bio::KBase::AppService::AppConfig->data_api_url;

my $script = Bio::KBase::AppService::AppScript->new(\&process_tree);
my $rc = $script->run(\@ARGV);
exit $rc;

sub process_tree
{
    my ($app, $app_def, $raw_params, $params) = @_;

    print "Process tree ", Dumper($app_def, $raw_params, $params);

    my $token = $app->token();

    if (!$token->token && -t STDIN)
    {
	if (open(T, "<", "$ENV{HOME}/.patric_token"))
	{
	    $token = <T>;
	    chomp $token;
	}
    }
    $token = $token->token if ref($token);

    my $ws = $app->workspace;
    my $output_folder = $app->result_folder();
    my $output_path = $params->{output_path};
    my $output_base = $params->{output_file};

    my $run_name = $output_base;
    $run_name =~ s/\W+/_/g;

    my @tmp_args;
    if (-t STDIN)
    {
	@tmp_args = (CLEANUP => 0);
    }
    my $tmpdir = File::Temp->newdir(@tmp_args);
    print STDERR "tmpdir = $tmpdir @tmp_args\n";

    print "api=$data_api_url\n";
    my $data_api = P3DataAPI->new($data_api_url, $token);

    my @in_genomes;
    my @out_genomes;

    #
    # Determine species for genomes to enable/disable unique species filter
    #
    
    my %species;
    my $q = join(",", @{$params->{in_genome_ids}});
    
    my @res = $data_api->query("genome",
			       ["in", "genome_id", "($q)"],
			       ["select", "genome_id", "species"]);
    push(@{$species{$_->{species}}}, $_->{genome_id}) foreach @res;
    print STDERR Dumper(\%species);
    for my $in_genome (@{$params->{in_genome_ids}})
    {
	my $path = "$tmpdir/$in_genome.faa";
	open(my $fh, ">", $path) or die "Cannot write $path: $!";
	$data_api->retrieve_protein_features_in_genome_in_export_format($in_genome, $fh);
	close($fh);
	push(@in_genomes, $path);
    }
    for my $out_genome (@{$params->{out_genome_ids}})
    {
	my $path = "$tmpdir/$out_genome.faa";
	open(my $fh, ">", $path) or die "Cannot write $path: $!";
	$data_api->retrieve_protein_features_in_genome_in_export_format($out_genome, $fh);
	close($fh);
	push(@out_genomes, $path);
    }
    my $pepr = "$ENV{KB_RUNTIME}/pepr/scripts/pepr.sh";
    -x $pepr or die "Cannot find pepr.sh at $pepr\n";
    my @cmd = ($pepr,
	       "-run_name", $run_name,
	       "-genome_file", @in_genomes,
	       "-outgroup", @out_genomes,
	       "-outgroup_count", scalar @out_genomes,
	       "-max_concurrent_processes", $max_processes,
	       "-patric"
	      );

    if (keys(%species) == 1)
    {
	push(@cmd, "-unique_species", "false");
    }

    my %valid_method = (ml => 1, parsimony_bl => 1, FastTree => 1);
    if ($params->{full_tree_method})
    {
	if ($valid_method{$params->{full_tree_method}})
	{
	    push(@cmd, "-full_tree_method", $params->{full_tree_method});
	}
	else
	{
	    die "Invalid full_tree_method value $params->{full_tree_method}";
	}
    }

    my %valid_refinement = (yes => "true", true => "true", no => "false", false => "false");
    if (my $ref = $params->{refinement})
    {
	my $val = $valid_refinement{lc($ref)};
	if ($val)
	{
	    push(@cmd, "-refine", $val);
	}
	else
	{
	    die "Invalid refinement value $ref\n";
	}
    }

    my $out_file = "$run_name.out";

    print Dumper(\@cmd, \@in_genomes, \@out_genomes, $token);
    my $init = sub {
	chdir $tmpdir or die "Cannot chdir $tmpdir: $!";
	$ENV{PATH} = "$ENV{KB_RUNTIME}/pepr/bin:$ENV{KB_RUNTIME}/bin:$ENV{PATH}";
	print STDERR "in init PATH=$ENV{PATH}";
	system("ls -l");
    };
    my $ok = run(\@cmd, init => $init, ">", $out_file);
    print STDERR "Command returns ok=$ok ret=$?\n";
    if (!$ok)
    {
	die "Failed running ($?) command @cmd\n";
    }

    my $failed;

    #
    # Failed run still creates a 1-byte newick fiel.
    #
    if (-s "$tmpdir/$run_name.nwk" > 1)
    {
	$ok = run(["svr_tree_to_html"], 
		  "<", "$tmpdir/$run_name.nwk",
		  ">", "$tmpdir/$run_name.html");
	$ok or warn "Error running svr_tree_to_html";
    }
    else
    {
	open(OUT, "<", $out_file);
	print STDERR $_ while (<OUT>);
	close(OUT);
	$failed = "Tree builder did not produce a tree";
    }

    my @output = (["$tmpdir/$run_name.nwk", "$output_folder/$output_base.nwk", 'nwk'],
		  ["$tmpdir/pepr.log", "$output_folder/$output_base.log", "txt"],
		  ["$tmpdir/$run_name.json", "$output_folder/$output_base.json", "json"],
		  ["$tmpdir/$run_name.sup", "$output_folder/$output_base.sup", "nwk"],
		  ["$tmpdir/$run_name.html", "$output_folder/$output_base.html", "html"],
		  [$out_file, "$output_folder/$output_base.out", "txt"],
		 );
    for my $out (@output)
    {
	my($path, $wspath, $type) = @$out;
	if (-f $path)
	{
	    print STDERR "Save $path to $wspath as $type\n";
	    $ws->save_file_to_file($path, {}, $wspath, $type, 1, 1, $token);
	}
	else
	{
	    print STDERR "File $path not found\n";
	}
    }
    die $failed if $failed;
}
