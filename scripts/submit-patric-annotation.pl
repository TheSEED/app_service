#
# Submit a set of genome annotation files to PATRIC for batch annotation as
# part of a site update.
#

use strict;
use Getopt::Long::Descriptive;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::Client;
use Try::Tiny;
use IO::Handle;
use Data::Dumper;
use File::Basename;

my($opt, $usage) = describe_options("%c %o workspace-dir input-file [input file ...]",
				    ["scientific-name=s", "Scientific name for this genome"],
				    ["taxonomy-id=i", "NCBI taxonomy ID for this genome"],
				    ["genetic-code=i", "Genetic code for this genome (11 or 4)", { default => 11 }],
				    ["domain=s", "Domain for this genome (Bacteria or Archaea)", { default => 'B' }],
				    ["public", "Mark the genomes public"],
				    ["index-nowait", "Don't wait for indexing to complete before marking job done"],
				    ["log=s", "Logfile"],
				    ["workspace-url=s", "Use this workspace URL"],
				    ["app-service-url=s", "Use this app service URL"],
				    ["test", "Submit to test service"],
				    ["clientgroup=s", "Use this AWE clientgroup instead of the default"],
				    ["help|h", "Show this help message"],
				    );

print($usage->text), exit(0) if $opt->help;
die($usage->text) if @ARGV < 2;

my $ws_dir = shift;
my @input_files = @ARGV;

my $log_fh;
if ($opt->log)
{
    open($log_fh, ">>", $opt->log) or die "Cannot open " . $opt->log . " for writing: $!";
    $log_fh->autoflush(1);
}
else
{
    $log_fh = \*STDERR;
}

my $interactive = $ENV{KB_INTERACTIVE} || (-t STDIN);
my $token = Bio::KBase::AuthToken->new(ignore_authrc => ($interactive ? 0 : 1));

my $ws = Bio::P3::Workspace::WorkspaceClientExt->new($opt->workspace_url);
my $app_service = Bio::KBase::AppService::Client->new($opt->app_service_url);

my %valid_genetic_code = (11 => 1, 4 => 1);
my @valid_domain = ([qr/^b/i => 'B'],
		    [qr/^v/i => 'V'],
		    [qr/^a/i => 'A'],
		    [qr/^e/i => 'E']);

if ($opt->genetic_code)
{
    $valid_genetic_code{$opt->genetic_code} or die "Invalid genetic code " . $opt->genetic_code;
}

$opt->scientific_name or die "Scientific name must be specified using the --scientific-name flag\n";
$opt->taxonomy_id or die "NCBI taxonomy id must be specified using the --taxonomy-id flag\n";

my $domain;

if ($opt->domain)
{
    for my $d (@valid_domain)
    {
	print "Match " . $opt->domain . " against @$d\n";
	if ($opt->domain =~ $d->[0])
	{
	    $domain = $d->[1];
	}
    }
    $domain or die "Invalid domain " . $opt->domain;
    print "Domain=$domain\n";
}

#
# Ensure the workspace path is there, if possible.
#
try {
    my $res = $ws->get({ objects => [$ws_dir], metadata_only => 1 });
    print Dumper($res);
} catch {
    my($err) = /_ERROR_(.*)_ERROR_/;
    if ($err =~ /Object not found/)
    {
	ws_mkdir($ws_dir);
    }
    else
    {
	die "Workspace error: $err\n";
    }
};

my @to_process;
for my $file (@input_files)
{
    my $base_file = basename($file);
    my $dir = basename($file);
    $dir =~ s/\.[^.]*$//;
    my $path = "$ws_dir/$dir";

    push(@to_process, [$file, $base_file, $path, $dir]);
}
ws_mkdir(map { $_->[2] } @to_process);

for my $ent (@to_process)
{
    my($file, $base_file, $dir, $base) = @$ent;
    my $ws_path = "$dir/$base_file";
    print STDERR "Uploading $file to workspace at $ws_path\n";
    my $res = $ws->save_file_to_file($file, {}, $ws_path, "contigs", 1, 1, $token);

    print STDERR "Submitting\n";
    my $params = {
	contigs => $ws_path,
	scientific_name => $opt->scientific_name,
	taxonomy_id => $opt->taxonomy_id,
	code => $opt->genetic_code,
	domain => $domain,
	output_path => $dir,
	output_file => $base,
	public => ($opt->public ? 1 : 0),
	queue_nowait => ($opt->index_nowait ? 1 : 0),
	($opt->clientgroup ? (_clientgroup => $opt->clientgroup) : ()),
    };

    try {
	my $app = $opt->test ? "GenomeAnnotationTest" : "GenomeAnnotation";
	my $task = $app_service->start_app($app, $params, $ws_path);
	print "Created task $task\n";
	print Dumper($task);
	print $log_fh "$file\t$ws_path\t$task->{id}\n";
    } catch {
	die "Failure creating task for $file: $_";
    };
}
			  
sub ws_mkdir
{
    my(@paths) = @_;

    try {
	my $ret = $ws->create({ objects => [ map { [$_, 'folder'] } @paths ] });
    } catch {
	if (my($err) = /_ERROR_(.*)_ERROR_/)
	{
	    die "Workspace error: $err\n";
	}
	else
	{
	    die "Error on create: $_\n";
	}
    };
}
