#
# The Genome Assembly application.
#

use strict;
use Carp;
use Data::Dumper;

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AuthToken;
use Bio::P3::Workspace::WorkspaceClient;

my $script = Bio::KBase::AppService::AppScript->new(\&process_reads);

$script->run(\@ARGV);

sub process_reads {
    my($app_def, $raw_params, $params) = @_;

    print "Proc genome ", Dumper($app_def, $raw_params, $params);

    # my $token = Bio::KBase::AuthToken->new(ignore_authrc => 1);
    # if ($token->validate()) {
        # print "Token validated\n";
    # }

    my $ws = Bio::P3::Workspace::WorkspaceClient->new();

    verify_cmd("ar-run") and verify_cmd("ar-get");

    my $output_path = $params->{output_path};
    my $output_base = $params->{output_file};
    my $output_name = "$output_base.contigs";

    my $recipe = $params->{recipe};
    my $method = "-r $recipe" if $recipe;

    my @ai_params = parse_input($params);

    my $cmd = join(" ", @ai_params);
    $cmd = "ar-run $method $cmd | ar-get -w -p > $output_name";
    print "$cmd\n";

    run($cmd);

    $ws->save_objects({ objects => [[$output_path, $output_name, $output_name, "Contigs"]], overwrite => 1 });

}

my $global_ws;
sub get_ws_file {
    my ($id) = @_;
    # return $id;
    my ($path, $obj) = $id =~ m|^(.*)/([^/]+)$|;
    my $ws = $global_ws || Bio::P3::Workspace::WorkspaceClient->new();
    $global_ws ||= $ws;
    my $res = $ws->get_objects({ objects => [[$path, $obj]] });

    ref($res) eq 'ARRAY' && @$res && $res->[0]->{data}
        or die "Could not get ws object: $id\n";

    return $res->[0]->{data};
}

sub parse_input {
    my ($input) = @_;

    my @params;
    
    my ($pes, $ses, $ref) = ($input->{paired_end_libs}, $input->{single_end_libs}, $input->{reference_assembly});

    for (@$pes) { push @params, parse_pe_lib($_) }
    for (@$ses) { push @params, parse_se_lib($_) }
    push @params, parse_ref($ref);

    return @params;
}

sub parse_pe_lib {
    my ($lib) = @_;
    my @params;
    push @params, "--pair";
    push @params, get_ws_file($lib->{read1});
    push @params, get_ws_file($lib->{read2});
    my @ks = qw(insert_size_mean insert_size_std_dev);
    for my $k (@ks) {
        push @params, $k."=".$lib->{$k} if $lib->{$k};
    }
    return @params;
}

sub parse_se_lib {
    my ($lib) = @_;
    my @params;
    push @params, "--single";
    push @params, get_ws_file($lib);
    return @params;
}

sub parse_ref {
    my ($ref) = @_;
    my @params;
    push @params, "--reference";
    push @params, get_ws_file($ref);
    return @params;
}


sub verify_cmd {
    my ($cmd) = @_;
    system("which $cmd >/dev/null") == 0 or die "Command not found: $cmd\n";
}

sub run { system(@_) == 0 or confess("FAILED: ". join(" ", @_)); }

