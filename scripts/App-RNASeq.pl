#
# The RNASeq Analysis application.
#

use strict;
use Carp;
use Data::Dumper;
use File::Temp;
use File::Basename;
use IPC::Run 'run';

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;

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
    
    my $tmpdir = File::Temp->newdir();
    # my $tmpdir = File::Temp->newdir( CLEANUP => 0 );
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
					       (-s "$ofile" > 10_000 ? 1 : 0), # use shock for larger files
					       $global_token);
	} else {
	    warn "Missing desired output file $ofile\n";
	}
    }

}

sub run_rna_rocket {
    my ($params, $tmpdir) = @_;
}

sub run_rockhopper {
    my ($params, $tmpdir) = @_;

    my $exps = params_to_exps($params);
    my $labels = $params->{experimental_conditions};
    my $stranded = defined($params->{strand_specific}) && !$params->{strand_specific} ? 0 : 1;

    print "Run rockhopper ", Dumper($exps, $labels, $tmpdir);

    my $jar = "/home/fangfang/programs/Rockhopper.jar";
    -s $jar or die "Could not find Rockhopper: $jar\n";

    my $outdir = "$tmpdir/Rockhopper";

    my @cmd = (qw(java -Xmx1200m -cp), $jar, "Rockhopper");

    print STDERR '$exps = '. Dumper($exps);
    
    # push @cmd, qw(-SAM -TIME);
    push @cmd, ("-o", $outdir);
    push @cmd, qw(-s false) unless $stranded;
    push @cmd, ("-L", join(",", map { s/\s+//g; $_ } @$labels)) if $labels && @$labels;
    push @cmd, map { my @s = @$_; join(",", map { join("%", @$_) } @s) } @$exps;

    print STDERR "cmd = ", join(" ", @cmd) . "\n\n";

    my ($rc, $out, $err) = run_cmd(\@cmd);
    print STDERR "STDOUT:\n$out\n";
    print STDERR "STDERR:\n$err\n";

    run("echo $outdir && ls -ltr $outdir");

    my @files = glob("$outdir/*.txt");
    my @outputs = map { [ $_, 'unspecified' ] } @files;
    return @outputs;
}

sub run_cmd {
    my ($cmd) = @_;
    my ($out, $err);
    my $rc = run($cmd, '>', \$out, '2>', \$err);
    # $rc and die "Error running cmd=@$cmd, stdout:\n$out\nstderr:\n$err\n";
    # print STDERR "STDOUT:\n$out\n";
    # print STDERR "STDERR:\n$err\n";
    return ($rc, $out, $err);
}

sub params_to_exps {
    my ($params) = @_;
    my @exps;
    for (@{$params->{paired_end_libs}}) {
        my $index = $_->{condition} - 1;
        push @{$exps[$index]}, [ $_->{read1}, $_->{read2} ];
    }    
    for (@{$params->{single_end_libs}}) {
        my $index = $_->{condition} - 1;
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


