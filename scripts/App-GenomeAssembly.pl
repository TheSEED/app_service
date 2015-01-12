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

    my $token = get_token();
    my $ws = get_ws();
    my $meta;

    $ws->save_data_to_file(slurp_input($output_name), $meta, "$output_path/$output_name", undef,
                           1, 1, $token);
}

my $global_ws;
sub get_ws {
    my $ws = $global_ws || Bio::P3::Workspace::WorkspaceClientExt->new();
    $global_ws ||= $ws;
    return $ws;
}

my $global_token;
sub get_token {
    my $token = $global_token || Bio::KBase::AuthToken->new(ignore_authrc => 0);
    $token && $token->validate() or die "No token or invalid token\n";
    $global_token ||= $token;
}
 
my $global_file_count;
sub get_ws_file {
    my ($id) = @_;
    # return $id;
    my ($path, $name) = $id =~ m|^(.*)/([^/]+)$|;

    my $ws = get_ws();
    my $token = get_token();
    
    my $fh;
    my $fname = join('', 'f', ++$global_file_count, '_', $name);
    open($fh, ">$fname") or die "Could not open $fname";
    $ws->copy_files_to_handles(1, $token, [[$id, $fh]]);
    close($fh);
             
    return $fname;
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
