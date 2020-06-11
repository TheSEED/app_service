=head1 NAME
    
    p3x-qstat - show the PATRIC application service queue
    
=head1 SYNOPSIS

    p3x-qstat [OPTION]...
    
=head1 DESCRIPTION

Queries the PATRIC application service queue.

=cut

use 5.010;    
use strict;
use DBI;
use Data::Dumper;
use JSON::XS;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name);
use Bio::P3::Workspace::WorkspaceClientExt;

use Text::Table::Tiny 'generate_table';
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o [jobid...]",
				    ["application|A=s" => "Limit results to the given application"],
				    ["status|s=s" => "Limit results to jobs with the given status code"],
				    ["start-time=s" => "Limit results to jobs submitted at or after this time"],
				    ["end-time=s" => "Limit results to jobs submitted before this time"],
				    ["genome-id" => "For genome annotation jobs, look up the genome ID if possible"],
				    ["user|u=s" => "Limit results to the given user"],
				    ["cluster|c=s" => "Limit results to the given cluster"],
				    ["slurm" => "Interpret job IDs as Slurm job IDs"],
				    ["n-jobs|n=i" => "Limit to the given number of jobs", { default => 50 } ],
				    ["parsable" => "Generate tab-delimited output"],
				    ["no-header" => "Skip printing header"],
				    ["help|h" => "Show this help message."],
				    );
print($usage->text), exit 0 if $opt->help;
my $ws = Bio::P3::Workspace::WorkspaceClientExt->new();

my $port = sched_db_port // 3306;
my $dbh = DBI->connect("dbi:mysql:" . sched_db_name . ";host=" . sched_db_host . ";port=$port",
		       sched_db_user, sched_db_pass);
$dbh or die "Cannot connect to database: " . $DBI::errstr;
$dbh->do(qq(SET time_zone = "+00:00"));


#
# Basic query is to enumerate all queued and running jobs.
#

my @conds;
my @params;
push(@conds, 'true');

if ($opt->start_time)
{
    push(@conds, 't.submit_time >= ?');
    push(@params, $opt->start_time);
}

if ($opt->end_time)
{
    push(@conds, 't.submit_time < ?');
    push(@params, $opt->end_time);
}

if ($opt->application)
{
    push(@conds, "t.application_id = ?");
    push(@params, $opt->application);
}

if ($opt->cluster)
{
    push(@conds, "cj.cluster_id = ?");
    push(@params, $opt->cluster);
}
 
if ($opt->status)
{
    push(@conds, "t.state_code = ?");
    push(@params, $opt->status);
}

if (my $u = $opt->user)
{
    if ($u !~ /@/)
    {
	$u .= '@patricbrc.org';
    }
    push(@conds, "t.owner = ?");
    push(@params, $u);
}

my @sort = ('submit_time DESC');
my $sort = join(", ", @sort);

if (@ARGV)
{
    #
    # Only query the given job ids.
    #
    for my $id (@ARGV)
    {
	if ($id !~ /^\d+$/)
	{
	    die "Invalid job id $id\n";
	}
    }
    my $vals = join(", ", @ARGV);

    #
    # Choose the right kind of job ID to search for.
    #
    my $field;
    if ($opt->slurm)
    {
	$field = "cj.job_id";
    }
    else
    {
	$field = "t.id";
    }

    push(@conds, "$field IN ($vals)");
}

push(@conds, "te.active = 1 or te.active IS NULL");

my $cond = join(" AND ", map { "($_)" } @conds);

my $limit;
if ($opt->n_jobs)
{
    $limit = "LIMIT " . $opt->n_jobs;
}

my $qry = qq(SELECT t.id as task_id, t.state_code, t.owner, t.application_id,  
	     t.submit_time, t.start_time, t.finish_time, timediff(t.finish_time, t.start_time) as elap,
	     t.output_path, t.output_file, t.params,
	     cj.job_id, cj.job_status, cj.maxrss, cj.cluster_id, cj.nodelist,
	     ts.description as task_state
	     FROM Task t JOIN TaskState ts on t.state_code = ts.code
	     LEFT OUTER JOIN TaskExecution te ON te.task_id = t.id 
	     LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
	     WHERE $cond
	     ORDER BY $sort
	     $limit
	     );
#die Dumper($qry, @params);
my @cols;
push(@cols,
 { title => "Job ID" },
 { title => "State" },
 { title => "Owner" },
 { title => "Application" },
 { title => "Submitted" },
 { title => "Elapsed" },
 { title => "Cluster" },
 { title => "Cl job" },
 { title => "Cl job status"},
 { title => "Nodes" },
 { title => "RAM used" },
     );

if ($opt->genome_id)
{
    push(@cols, { title => "Genome ID" });
    push(@cols, { title => "Indexing skipped" });
}

if ($opt->parsable && !$opt->no_header)
{
    say join("\t", map { $_->{title} } @cols);
}

#my $tbl = Text::Table->new(@cols);

my $sth = $dbh->prepare($qry);
$sth->execute(@params);
my @rows;

push(@rows, [map { $_->{title} } @cols]);

while (my $task = $sth->fetchrow_hashref)
{
    my $genome_id;
    my $indexing_skipped = 0;
    if ($opt->genome_id && $task->{application_id} eq 'GenomeAnnotation')
    {
	#
	# If we are on the host with the output data, try looking there.
	#
	my $path = "/disks/p3/task_status/$task->{task_id}/stdout";
	if (open(F, "<", $path))
	{
	    while (<F>)
	    {
		if (/^1\s+'(\d+\.\d+)'\s*$/)
		{
		    $genome_id = $1;
		    last;
		}
	    }
	    close(F);

	}
	if (!$genome_id)
	{
	    eval {
		my $path = "$task->{output_path}/.$task->{output_file}/$task->{output_file}.genome";
		my $txt;
		my $fh;
		open($fh, ">", \$txt);
		$ws->copy_files_to_handles(1, undef, [[$path, $fh]], { admin => 1 });
		my $obj = decode_json($txt);
		$genome_id = $obj->{id};
	    };
	    if ($@)
	    {
		warn $@;
	    }
	}
	eval {
	    my $x = decode_json($task->{params});
	    $indexing_skipped = $x->{skip_indexing} ? 1 : 0;
	}
    }

    (my $owner = $task->{owner}) =~ s/\@patricbrc.org$//;
    my @row = ($task->{task_id}, $task->{task_state}, $owner, $task->{application_id},
	      $task->{submit_time}, $task->{elap},
	      $task->{job_id} ? ($task->{cluster_id}, $task->{job_id}, $task->{job_status}, $task->{nodelist}, int($task->{maxrss})) : ());
    push(@row, $genome_id, $indexing_skipped) if $opt->genome_id;
    push(@rows, \@row);

    if ($opt->parsable)
    {
	say join("\t", @row);
    }
}

#print $tbl;

if (!$opt->parsable)
{
    say generate_table(rows => \@rows, header_row => 1);
}
