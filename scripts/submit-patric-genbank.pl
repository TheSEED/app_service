#
# Submit a set of genbank files to PATRIC for batch annotation as
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
use JSON::XS;

my($opt, $usage) = describe_options("%c %o ws-dir genbank-file [genbank-file ...]",
				    ["Process the given set of genbank files for annotation. Use ws-dir as the base directory to store the input and output data in the PATRIC workspace"],
				    ["workflow-file=s", "Use a custom workflow as defined in this file."],
				    ["import-only", "Import this genome as is - do not reannotate gene calls or gene function."],
				    ["public", "Mark the genomes public", { hidden => 1 }],
				    ["index-nowait", "Don't wait for indexing to complete before marking job done"],
				    ["log=s", "Logfile"],
				    ["workspace-url=s", "Use this workspace URL"],
				    ["app-service-url=s", "Use this app service URL"],
				    ["test", "Submit to test service", { hidden => 1 }],
				    ["clientgroup=s", "Use this AWE clientgroup instead of the default", { hidden => 1 }],
				    ["help|h", "Show this help message"],
				    );

print($usage->text), exit(0) if $opt->help;
die($usage->text) if @ARGV < 2;

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

if ($opt->workflow_file && $opt->import_only)
{
    die "A custom workflow may not be supplied when using --import-only\n";
}

my $workflow;
my $workflow_txt;
if ($opt->workflow_file)
{
    open(F, "<", $opt->workflow_file) or die "Cannot open workflow file " . $opt->workflow_file . ": $!\n";
    local $/;
    undef $/;
    $workflow_txt = <F>;
    close(F);
    eval {
	$workflow = decode_json($workflow_txt);
    };
    if (!$workflow)
    {
	die "Error parsing workflow file " . $opt->workflow_file . "\n";
    }

    if (ref($workflow) ne 'HASH' ||
	!exists($workflow->{stages}) ||
	ref($workflow->{stages}) ne 'ARRAY')
    {
	die "Invalid workflow document (must be a object containing a list of stage definitions)\n";
    }
}

my $ws = Bio::P3::Workspace::WorkspaceClientExt->new($opt->workspace_url);
my $app_service = Bio::KBase::AppService::Client->new($opt->app_service_url);

my $ws_dir = shift;
my @genbank_files = @ARGV;
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
for my $gb (@genbank_files)
{
    my $base_file = basename($gb);
    my $dir = basename($gb);
    $dir =~ s/\.[^.]*$//;
    my $path = "$ws_dir/$dir";

    push(@to_process, [$gb, $base_file, $path, $dir]);
}
ws_mkdir(map { $_->[2] } @to_process);

for my $ent (@to_process)
{
    my($file, $base_file, $dir, $base) = @$ent;
    my $ws_path = "$dir/$base_file";
    print STDERR "Uploading $file to workspace at $ws_path\n";
    my $res = $ws->save_file_to_file($file, {}, $ws_path, "genbank_file", 1, 1, $token);

    print STDERR "Submitting\n";
    my $params = {
	genbank_file => $ws_path,
	output_path => $dir,
	output_file => $base,
	public => ($opt->public ? 1 : 0),
	queue_nowait => ($opt->index_nowait ? 1 : 0),
	($opt->clientgroup ? (_clientgroup => $opt->clientgroup) : ()),
	(defined($workflow_txt) ? (workflow => $workflow_txt) : ()),
	import_only => ($opt->import_only ? 1 : 0),
    };

    try {
	my $app = $opt->test ? "GenomeAnnotationGenbankTest" : "GenomeAnnotationGenbank";
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
