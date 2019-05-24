use strict;
use P3DataAPI;

use Data::Dumper;
use IPC::Run 'run';
use File::Slurp;
use JSON::XS;

use Bio::KBase::AppService::AppConfig;
use Bio::KBase::AppService::AppScript;

my $max_processes = $ENV{P3_ALLOCATED_CPU} // 8;

my $data_api_url = Bio::KBase::AppService::AppConfig->data_api_url;

my $script = Bio::KBase::AppService::AppScript->new(\&process_tree, \&preflight);
my $rc = $script->run(\@ARGV);
exit $rc;

sub preflight
{
    my($app, $app_def, $raw_params, $params) = @_;

    my $time = 86400 * 2;

    if ($task_params->{full_tree_method} ne 'ml')
    {
	$time = 3600 * 12;
    }

    my $pf = {
	cpu => 8,
	memory => "128G",
	runtime => $time,
	storage => 0,
	is_control_task => 0,
    };
    return $pf;
}

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
    #
    # For now always leave tmps around to look at.
    @tmp_args = (CLEANUP => 0);
    my $tmpdir = File::Temp->newdir(@tmp_args);
    print STDERR "tmpdir = $tmpdir @tmp_args\n";

    #
    # Make tempdir readable for debugging purposes
    #
    chmod(0755, $tmpdir);

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

    my %valid_method = (ml => 'ml',
			parsimony_bl => 'parsimony_bl',
			ft => 'FastTree',
			FastTree => 'FastTree');
    
    if ($params->{full_tree_method})
    {
	if (my $meth = $valid_method{$params->{full_tree_method}})
	{
	    push(@cmd, "-full_tree_method", $meth);
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

    print "Begin run. cmd=@cmd\n";
    print "In-genomes: @in_genomes\n";
    print "Out-genomes: @out_genomes\n";

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
    # Copy the pepr.log to the current directory for debugging purposes.
    #

    my @pepr_logs;
    my @pepr_logs_out;
    if (opendir(DH, $tmpdir))
    {
	for my $x (readdir(DH))
	{
	    my $p = "$tmpdir/$x";
	    if ($x =~ /^pepr\.log/ && -f $p)
	    {
		system("cp", $p, ".");
		push(@pepr_logs, $p);
		push(@pepr_logs_out, [$p, "$output_folder/$output_base.$x", 'txt']);
	    }
	}
    }


    #
    # Output is written to the json file. Extract the tree from it
    # and write to the newick file.
    #
    
    my $tree_json = read_file("$tmpdir/$run_name.json", err_mode => 'carp');
    if (!defined($tree_json))
    {
	warn "Error reading $tmpdir/$run_name.json: $!";
	$failed = "Error reading $tmpdir/$run_name.json: $!";
    }
    my $tree_data = eval { decode_json($tree_json); };
    if ($@)
    {
	warn "Error decoding tree json data: $@";
	$failed = "Error decoding tree json data: $@";
    }

    if (exists $tree_data->{tree})
    {
	my $tree_nwk = $tree_data->{tree};
	if ($tree_nwk eq '')
	{
	    warn "Invalid tree in json data";
	    $failed = "Invalid tree in json data";;
	}
	else
	{
	    if (open(FT, ">", "$tmpdir/$run_name.final.nwk"))
	    {
		print FT $tree_nwk;
		close(FT);
		
		my $ok = run(['svr_tree_to_html', '-raw'],
			     "<", \$tree_nwk,
			     ">", "$tmpdir/$run_name.html");
		$ok or warn "Error code=$? running svr_tree_to_html";
	    }
	    else
	    {
		warn "Cannot write $tmpdir/$run_name.final.nwk: $!";
	    }
	    if (open(FT, ">", "$tmpdir/${run_name}_final_rooted.nwk"))
	    {
		print FT $tree_nwk;
		close(FT);
		
		my $ok = run(['svr_tree_to_html', '-raw'],
			     "<", \$tree_nwk,
			     ">", "$tmpdir/$run_name.rooted.html");
		$ok or warn "Error code=$? running svr_tree_to_html";
	    }
	    else
	    {
		warn "Cannot write $tmpdir/${run_name}_final_rooted.nwk: $!";
	    }
	}
    }
    else
    {
	warn "Missing tree in json data";
	$failed = "Missing tree in json data";;
    }

    my @output = (["$tmpdir/$run_name.final.nwk", "$output_folder/$output_base.final.nwk", 'nwk'],
		  ["$tmpdir/${run_name}_final_rooted.nwk", "$output_folder/$output_base.final_rooted.nwk", 'nwk'],
		  ["$tmpdir/$run_name.nwk", "$output_folder/$output_base.nwk", 'nwk'],
		  @pepr_logs_out,
		  ["$tmpdir/$run_name.json", "$output_folder/$output_base.json", "json"],
		  ["$tmpdir/${run_name}_final_rooted.json", "$output_folder/$output_base.final_rooted.json", "json"],
		  ["$tmpdir/$run_name.sup", "$output_folder/$output_base.sup", "nwk"],
		  ["$tmpdir/$run_name.html", "$output_folder/$output_base.html", "html"],
		  ["$tmpdir/$run_name.rooted.html", "$output_folder/$output_base.rooted.html", "html"],
		  ["$tmpdir/$run_name.report.xml", "$output_folder/$output_base.report.xml", "xml"],
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
