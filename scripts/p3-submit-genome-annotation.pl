=head1 Submit a PATRIC Genome Annotation Job

    p3-submit-genome-annotation [options] output-path output-name

Submit a genome to the PATRIC genome annotation service.

=head1 Usage synopsis

    p3-submit-genome-annotation [-h] output-path output-name

	Submit an annotation job with output written to output-path and named
	output-name.    

    	The following options describe the inputs to the annotation:

           --workspace-path-prefix STR   Prefix for workspace pathnames as given
    	   			   	 to input parameters.
           --workspace-upload-path STR	 If local pathnames are given as library or
	   			   	 reference assembly parameters, upload the
    					 files to this directory in the workspace.
    					 Defaults to the output path.
           --overwrite			 If a file to be uploaded already exists in
    	   				 the workspace, overwrite it on upload. Otherwise
    					 we will not continue the service submission.
    	   --genbank-file FILE		 A genbank file to be annotated.
	   --contigs FILE		 A file of DNA contigs to be annotated.
           --phage			 Set annotation defaults for phage annotation.
           --recipe NAME		 Use the given annotation recipe for this genome.
           --reference-genome GID	 The PATRIC identifier of a reference genome
	   		      		 whose annotations will be propagated as
					 part of this annotation.
    
    	The following options describe the genome to be annotated. In each case
	where the value for the specified option may be drawn from a submitted
	genbank file it is optional to supply the value. If a value is supplied,
	it will override the value in the genbank file.

           --scientific-name "Genus species strain"
	   		      	         Scientific name for this genome. 
	   --taxonomy-id NUM		 Numeric NCBI taxonomy ID for this genome.
	   		 		 If not specified an estimate will be
					 computed, and if that is not possible the 
					 catchall taxonomy ID 6666666 will be used.
	   --genetic-code NUM		 Genetic code for this genome; either 11 or 4.
	   		  		 If not specified defaults to 11 unless it 
					 can be determined from the declared or computed
					 taxonomy ID.
	   --domain STR			 Domain for this genome (Bacteria or Archaea)
	   

	Advanced options:

	   --workflow-file STR		 Use the given workflow document to process 
	   		   		 annotate this genome.
	   --index-nowait		 Do not wait for indexing to complete before
					 the job is marked as complete.
	   --no-index			 Do not index this genome. If this option
	   				 is selected the genome will not be visible
					 on the PATRIC website.

=cut

use strict;
use Getopt::Long::Descriptive;
use Bio::P3::Workspace::WorkspaceClientExt;
use Bio::KBase::AppService::Client;
use P3DataAPI;
use P3AuthToken;
use Try::Tiny;
use IO::Handle;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use File::Basename;
use JSON::XS;
use Pod::Usage;
use Fcntl ':mode';

my $token = P3AuthToken->new();
if (!$token->token())
{
    die "You must be logged in to PATRIC via the p3-login command to submit annotation jobs.\n";
}
my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();
my $app_service = Bio::KBase::AppService::Client->new();

my($opt, $usage) =
    describe_options("%c %o output-path output-name",
		     ["Submit an annotation job with output written to output-path and named output-name."],
		     ["The output-path parameter is a PATRIC workspace path."],
		     ["The output-name parameter is a name that will describe this annotation in the workspace."],
		     ["It may not contain slash (/) characters."],
		     [],
		     ["The following options describe the inputs to the annotation."],
		     [],
		     ["workspace-path-prefix|p=s", "Prefix for workspace pathnames as given to input parameters."],
		     ["workspace-upload-path|P=s", "If local pathnames are given as genbank or contigs file parameters, upload the files to this directory in the workspace. Defaults to the output path."],
		     ["overwrite|f", "If a file to be uploaded already exists in the workspace, overwrite it on upload. Otherwise we will not continue the service submission."],
		     ["genbank-file=s", "A genbank file to be annotated."],
		     ["contigs-file=s", "A file of DNA contigs to be annotated."],
		     ["phage", "Set defaults for phage annotation."],
		     ["recipe=s", "Use the given non-default recipe for this annotation"],
		     ["reference-genome=s", "The PATRIC identifier of a reference genome whose annotations will be propagated as part of this annotation."],
		     ["reference-virus=s", "The name of a virus from the VIGOR_DB collection to use as the reference for a vigor4 viral annotation."],
		     [],
		     ["The following options describe the genome to be annotated."],
		     ["In each case where the value for the specified option may be drawn"],
		     ["from a submitted genbank file it is optional to supply the value."],
		     ["If a value is supplied, it will override the value in the genbank file."],
		     [],
		     ["scientific-name|n=s", "Scientific name for this genome."],
		     ["taxonomy-id|t=i", "Numeric NCBI taxonomy ID for this genome. If not specified an estimate will be computed, and if that is not possible the catchall taxonomy ID 6666666 will be used."],
		     ["genetic-code|g=i", "Genetic code for this genome; either 11 or 4. If not specified defaults to 11 unless it can be determined from the declared or computed taxonomy ID."],
		     ["domain|d=s", "Domain for this genome (Bacteria or Archaea)"],
		     [],
		     ["Advanced options:"],
		     [],
		     ["workflow-file=s", "Use the given workflow document to process annotate this genome."],
		     ["import-only", "Import this genome as is - do not reannotate gene calls or gene function. Only valid for genbank file input."],
		     ["raw-import-only", "Perform a raw import on this this genome - do not reannotate gene calls or gene function and perform a bare minimum of postprocessing. Only valid for genbank file input"],
		     ["skip-contigs", "Do not load contigs data. Only valid for genbank file input."],
		     ["index-nowait", "Do not wait for indexing to complete before the job is marked as complete."],
		     ["no-index", "Do not index this genome. If this option is selected the genome will not be visible on the PATRIC website."],
		     ["no-workspace-output", "Do not write any workspace output."],
		     ["dry-run", "Dry run. Upload files and validate input but do not submit annotation"],
		     ["container-id=s", "Container id for non-default container execution", { hidden => 1 }],
		     ["indexing-url=s", "Specify an override data api for indexing", { hidden => 1 }],
		     ["public", "Make the indexed genome publicly available", { hidden => 1 }],
		     [],
		     ["help|h", "Show this help message"],
		    );
print($usage->text), exit 0 if $opt->help;
die($usage->text) if @ARGV != 2;

my $output_path = shift;
my $output_name = shift;

#
# Perform some validations. We might have been able to use the validation
# support in Getopt::Long::Descriptive but the error messages it emits
# are really not user-friendly.
#

if ($output_name =~ m,/,)
{
    die "The output path may not contain a slash character\n";
}

my($input_file, $input_mode, $app_name);

if ($opt->genbank_file && $opt->contigs_file)
{
    die "Only one of --genbank-file and --contigs-file may be specified\n";
}
if (!$opt->genbank_file && !$opt->contigs_file)
{
    die "One of --genbank-file or --contigs-file must be specified\n";
}
elsif ($opt->genbank_file)
{
    $input_file = $opt->genbank_file;
    $input_mode = 'genbank';
    $app_name = "GenomeAnnotationGenbank";
}
elsif ($opt->contigs_file)
{
    $input_file = $opt->contigs_file;
    $input_mode = 'contigs';
    $app_name = "GenomeAnnotation";
}

if ($opt->workflow_file && $opt->import_only)
{
    die "A custom workflow may not be supplied when using --import-only\n";
}
if ($opt->workflow_file && $opt->raw_import_only)
{
    die "A custom workflow may not be supplied when using --raw-import-only\n";
}
if ($opt->workflow_file && $opt->recipe)
{
    die "A custom workflow may not be supplied when using --recipe\n";
}

#
# Set up some defaults.
#
my $default_domain = "B";
my $default_taxon_id = 6666666;
my $default_scientific_name = "Unknown sp.";
my $default_genetic_code = 11;

if ($opt->phage)
{
    $opt->{recipe} = "phage" unless $opt->recipe;
    $default_domain = "V";
}

#
# we assume output is in workspace, so just clip the prefix.
#
$output_path = strip_ws_prefix($output_path);
$output_path = expand_workspace_path($output_path);
$output_path =~ s,/+$,, if $output_path ne '/';
#print Dumper($output_path, $opt);
$opt->{workspace_upload_path} = $output_path unless $opt->workspace_upload_path;

$output_path =~ s,/+$,,;

#
# Make sure it is a folder.
#
my $stat = $ws->stat($output_path);
if (!$stat || !S_ISDIR($stat->mode))
{
    die "Output path $output_path does not exist\n";
}

#
# Handle any file uploads required. This allows us to perform
# preflight computations on the genomic data in the workspace.
#

my @upload_queue;
my $input_wspath = process_filename($input_file);

my $errors = process_upload_queue(\@upload_queue);

die "Exiting due to upload errors\n" if $errors;


#
# Handle custom workflow. This may be either local or in
# the workspace.
#
my $workflow;
my $workflow_txt;
if ($opt->workflow_file)
{
    my $wf = $opt->workflow_file;
    my($wf_ws) = $wf =~ /^ws:(.*)/;

    if ($wf_ws)
    {
	$wf_ws = expand_workspace_path($wf_ws);
	$workflow_txt = $ws->download_file_to_string($wf_ws, $token);
    }
    else
    {
	open(F, "<", $opt->workflow_file) or die "Cannot open workflow file " . $opt->workflow_file . ": $!\n";
	local $/;
	undef $/;
	$workflow_txt = <F>;
	close(F);
    }
    
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

my $params = {
    output_path => $output_path,
    output_file => $output_name,
    queue_nowait => ($opt->index_nowait ? 1 : 0),
    ($opt->recipe ? (recipe => $opt->recipe) : ()),
    (defined($workflow) ? (workflow => $workflow_txt) : ()),
    ($opt->no_index ? (skip_indexing => 1) : ()),
    ($opt->no_workspace_output ? (skip_workspace_output => 1) : ()),
    ($opt->reference_virus ? (reference_virus_name => $opt->reference_virus) : ()),
    ($opt->container_id ? (container_id => $opt->container_id) : ()),
    ($opt->indexing_url ? (indexing_url => $opt->indexing_url) : ()),
    ($opt->public ? (public => 1) : ()),
};

if ($input_mode eq 'genbank')
{
    $params->{genbank_file} = strip_ws_prefix($input_wspath);
    $params->{import_only} = $opt->import_only ? 1 : 0;
    $params->{raw_import_only} = $opt->raw_import_only ? 1 : 0;
    $params->{skip_contigs} = $opt->skip_contigs ? 1 : 0;

    #
    # Overrides if given.
    #
    $params->{code} = $opt->genetic_code if $opt->genetic_code;
    $params->{scientific_name} = $opt->scientific_name if $opt->scientific_name;
    $params->{taxonomy_id} = $opt->taxonomy_id if $opt->taxonomy_id;
    $params->{domain} = $opt->domain if $opt->domain;
}
else
{
    $params->{contigs} = strip_ws_prefix($input_wspath);
    my $taxon_id = $opt->taxonomy_id;

    #
    # When we have a taxonomy estimation service, hook in here.
    #
    # else..
    #
    # Given a taxonomy ID, we look up scientific name, genetic
    # code, and domain.
    #
    my $api = P3DataAPI->new();

    if ($taxon_id)
    {
	#
	# If something has been omitted, attempt to look it up via the taxonomy
	# identifier.
	#
	
	if (!($opt->domain && $opt->scientific_name && $opt->genetic_code))
	{
	    my($db_domain, $db_name, $db_genetic_code);
	    
	    my @res = $api->query("taxonomy",
				  ["select", "lineage_names,genetic_code,taxon_name"],
				  ["eq", "taxon_id", $taxon_id]);
	    if (@res)
	    {
		my $t = $res[0];
		$db_name = $t->{taxon_name};
		$db_genetic_code = $t->{genetic_code};
		my $lin = $t->{lineage_names};
		shift @$lin if $lin->[0] =~ /^cellular/;
		$db_domain = $lin->[0];
	    }

	    $params->{domain} = $opt->domain // $db_domain;
	    $params->{code} = $opt->genetic_code // $db_genetic_code;
	    $params->{scientific_name} = $opt->scientific_name // $db_name;
	}
	else
	{
	    $params->{domain} = $opt->domain;
	    $params->{code} = $opt->genetic_code;
	    $params->{scientific_name} = $opt->scientific_name;
	}
	$params->{taxonomy_id} = $taxon_id;
    }
    else
    {
	$params->{taxonomy_id} = $default_taxon_id;
	$params->{domain} //= $default_domain;
	$params->{code} //= $default_genetic_code;
	$params->{scientific_name} //= $default_scientific_name;
    }
}
   
if ($opt->dry_run)
{
    print "Would submit with data:\n";
    print JSON::XS->new->pretty(1)->encode($params);
}
else
{
    my $task = eval { $app_service->start_app($app_name, $params, '') };
    if ($@)
    {
	die "Error submitting annotation to service:\n$@\n";
    }
    elsif (!$task)
    {
	die "Error submitting annotation to service (unknown error)\n";
    }
    print "Submitted annotation with id $task->{id}\n";
}

sub process_upload_queue
{
    my($upload_queue) = @_;
    my $errors;
    for my $ent (@$upload_queue)
    {
	my($path, $wspath) = @$ent;
	my $size = -s $path;
	printf "Uploading $path to $wspath (%s)...\n", format_size($size);
	my $res;
	eval {
	    $res = $ws->save_file_to_file($path, {}, $wspath, 'reads', $opt->overwrite, 1, $token->token());
	};
	if ($@)
	{
	    die "Failure uploading $path to $wspath\n";
	}
	my $stat = $ws->stat($wspath);
	if (!$stat)
	{
	    print "Error uploading (file was not present after upload)\n";
	    $errors++;
	}
	elsif ($stat->size != $size)
	{
	    printf "Error uploading (filesize at workspace (%s) did not match original size $size)\n",
	    $stat->size;
	    $errors++;
	}
	else
	{
	    print "done\n";
	}
    }
    return $errors;
}


sub format_size
{
    my($s) = @_;
    return sprintf "%.1f Gbytes", $s / 1e9 if ($s > 1e9);
    return sprintf "%.1f Mbytes", $s / 1e6 if ($s > 1e6);
    return sprintf "%.1f Kbytes", $s / 1e3 if ($s > 1e3);
    return "$s bytes";
}

sub strip_ws_prefix
{
    my($p) = @_;
    $p =~ s/^ws://;
    return $p;
}

sub process_filename
{
    my($path) = @_;
    my $wspath;
    if ($path =~ /^ws:(.*)/)
    {
	$wspath = expand_workspace_path($1);
	my $stat = $ws->stat($wspath);
	if (!$stat || !S_ISREG($stat->mode))
	{
	    die "Workspace path $wspath not found for file $path\n";
	}
    }
    else
    {
	if (!-f $path)
	{
	    die "Local file $path does not exist\n";
	}
	if (!$opt->workspace_upload_path)
	{
	    die "Upload was requested for $path but an upload path was not specified via --workspace-upload-path\n";
	}
	my $file = basename($path);
	$wspath = $opt->workspace_upload_path . "/" . $file;

	if (!$opt->overwrite && $ws->stat($wspath))
	{
	    die "Target path $wspath already exists and --overwrite not specified\n";
	}

	push(@upload_queue, [$path, $wspath]);
    }
    return $wspath;
}

sub expand_workspace_path
{
    my($wspath_in) = @_;
    my $wspath = $wspath_in;
    if ($wspath_in !~ m,^/,)
    {
	if (!$opt->workspace_path_prefix)
	{
	    die "Cannot process $wspath: no workspace path prefix set (--workspace-path-prefix parameter)\n";
	}
	$wspath = $opt->workspace_path_prefix ;
	$wspath =~ s,/+$,,;
	$wspath .= "/" . $wspath_in;
    }
    return $wspath;
}
