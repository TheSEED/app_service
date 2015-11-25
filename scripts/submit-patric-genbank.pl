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

my($opt, $usage) = describe_options("%c %o ws-dir genbank-file [genbank-file ...]",
				    ["Process the given set of genbank files for annotation. Use ws-dir as the base directory to store the input and output data in the PATRIC workspace"],
				    ["public", "Mark the genomes public"],
				    ["index-nowait", "Don't wait for indexing to complete before marking job done"],
				    ["log=s", "Logfile"],
				    ["workspace-url=s", "Use this workspace URL"],
				    ["app-service-url=s", "Use this app service URL"],
				    ["test", "Submit to test service"],
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
