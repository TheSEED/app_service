
use strict;
use Getopt::Long::Descriptive;
use Data::Dumper;
use Bio::P3::Workspace::WorkspaceClient;
use Bio::P3::Workspace::Utils;
use LWP::UserAgent;

=head1 NAME

appserv-upload-contigs

=head1 SYNOPSIS

appserv-upload-contigs filename workspace-path

=head1 DESCRIPTION

Copy a file into or out of the workspace.

=head1 COMMAND-LINE OPTIONS

ws-cp [-h] [long options...]
	--url       Service URL
	-h --help   Show this usage message
=cut

my @options = (
	       ["url=s", 'Service URL'],
	       ["help|h", "Show this usage message"],
	      );

my($opt, $usage) = describe_options("%c %o filename workspace-path",
				    @options);

print($usage->text), exit if $opt->help;
print($usage->text), exit 1 if @ARGV != 2;

my $file = shift;
my $path = shift;

my $ws = Bio::P3::Workspace::WorkspaceClient->new($opt->url);
my $wsutil = Bio::P3::Workspace::Utils->new($ws);

-f $file or die "File $file does not exist\n";

my $ua = LWP::UserAgent->new();

my($base, $obj) = $path =~ m,^(.*)/([^/]+)$,;
if (!$base || !$obj)
{
    die "Error parsing path $path\n";
}


my $nlist = $ws->create_upload_node({ objects => [[ $base, $obj, "Contigs" ]] });

if (!ref($nlist) || @$nlist == 0)
{
    die "create_upload_node failed\n";
}

my $node = $nlist->[0];

print "Post to $node\n";
my $req = HTTP::Request::Common::POST($node,
				      Authorization => "OAuth " . $wsutil->token->token,
				      Content_Type => 'multipart/form-data',
				      Content => [upload => [$file]]);
$req->method('PUT');
my $res = $ua->request($req);
if (!$res->is_success)
{
    die Dumper($res);
    die "Upload failed: " . $res->message . "\n" . $res->content;
}

			     
