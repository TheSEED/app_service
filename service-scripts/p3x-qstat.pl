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
use DateTime;
use JSON::XS;
use Bio::KBase::AppService::AppConfig qw(sched_db_host sched_db_port sched_db_user sched_db_pass sched_db_name);
use Bio::P3::Workspace::WorkspaceClientExt;

use Text::Table::Tiny 'generate_table';
use Getopt::Long::Descriptive;

my($opt, $usage) = describe_options("%c %o [jobid...]",
				    ["application|A=s" => "Limit results to the given application"],
				    ["status|s=s\@" => "Limit results to jobs with the given status code", { default => [] }],
				    ["submit-time=s" => "Limit results to jobs submitted at or after this time"],
				    ["start-time=s" => "Limit results to jobs started at or after this time"],
				    ["end-time=s" => "Limit results to jobs submitted before this time"],
				    ["genome-id" => "For genome annotation jobs, look up the genome ID if possible"],
				    ["ids-from=s" => "Use the given file to read IDs from"],
				    ["user-metadata=s" => "Limit to jobs with the given user metadata"],
				    ["show-output-file" => "Show the output filename"],
				    ["show-output-path" => "Show the output path"],
				    ["show-user-metadata" => "Show the user metadata"],
				    ["show-times" => "Show start and finish times"],
				    ["show-parameter=s\@" => "Show this parameter from the input parameters", { default => [] }],
				    ["show-count=s\@" => "Show this length of this input parameter (if it is a list)", { default => [] }],
				    ["show-all-parameters" => "Show all parameters"],
				    ["elapsed-seconds" => "Show elapsed time in seconds"],
				    ["user|u=s" => "Limit results to the given user"],
				    ["cluster|c=s" => "Limit results to the given cluster"],
				    ["compute-node|N=s\@" => "Limit results to the given compute node", { default => [] }],
				    ["slurm" => "Interpret job IDs as Slurm job IDs"],
				    ["count" => "Print a count of matching records only"],
				    ["sort-by-ram" => "Sort by memory used"],
				    ["n-jobs|n=i" => "Limit to the given number of jobs", { default => 50 } ],
				    ["show-inactive-jobs" => "Include inactive cluster jobs"],
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
# $dbh->do(qq(SET time_zone = "+00:00"));


#
# Basic query is to enumerate all queued and running jobs.
#

my @conds;
my @params;
push(@conds, 'true');

if ($opt->compute_node)
{
    my $list = $opt->compute_node;
    if (@$list)
    {
	my $nl = join(",", map { $dbh->quote($_) } @$list);
	push(@conds, "cj.nodelist IN ($nl)");
    }
}

if ($opt->user_metadata)
{
    push(@conds, 't.user_metadata = ?');
    push(@params, $opt->user_metadata);
}

if ($opt->submit_time)
{
    push(@conds, 't.submit_time >= ?');
    push(@params, $opt->submit_time);
}

if ($opt->start_time)
{
    push(@conds, 't.start_time >= ?');
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
 
if (my @slist = @{$opt->status})
{
    push(@conds, "t.state_code IN (" . join(",", map { "?" } @slist) . ")");
    push(@params, @slist);
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

my @sort = ('t.submit_time DESC');
if ($opt->sort_by_ram)
{
    unshift(@sort, 'cj.maxrss DESC');
}
my $sort = join(", ", @sort);

my @ids;
if ($opt->ids_from)
{
    my $fh;
    if ($opt->ids_from eq '-')
    {
	$fh = \*STDIN;
    }
    else
    {
	open($fh, "<", $opt->ids_from) or die "Cannot open " . $opt->ids_from . ": $!\n";
    }
    while (<$fh>)
    {
	if (/^\s*(\d+)/)
	{
	    push(@ids, $1);
	}
    }
    close $fh unless $opt->ids_from eq '-';
}
else
{
    @ids = @ARGV;
}

if (@ids)
{
    #
    # Only query the given job ids.
    #
    my @vals;
    for my $id (@ids)
    {
	if ($id =~ /^(\d+),?$/)
	{
	    push(@vals, $1);
	}
	else
	{
	    die "Invalid job id $id\n";
	}
    }
    my $vals = join(", ", @vals);

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

if (!$opt->show_inactive_jobs)
{
    push(@conds, "te.active = 1 or te.active IS NULL");
}

my $cond = join(" AND ", map { "($_)" } @conds);

my $limit;
if ($opt->n_jobs)
{
    $limit = "LIMIT " . $opt->n_jobs;
}

#
# Look up the task states to make the query that follows faster.
#
my $task_state_info = $dbh->selectall_hashref(qq(SELECT code, description FROM TaskState), 'code');

my $full_condition = qq(FROM Task t LEFT OUTER JOIN TaskExecution te ON te.task_id = t.id 
			LEFT OUTER JOIN ClusterJob cj ON cj.id = te.cluster_job_id
			WHERE $cond);

if ($opt->count)
{
    my $qry = qq(SELECT COUNT(t.id) $full_condition);
    # print "$qry\n";
    my $res = $dbh->selectcol_arrayref($qry, undef, @params);
    print "$res->[0]\n";
    exit 0;
}


my $qry = qq(SELECT t.id as task_id, t.state_code, t.owner, t.application_id,  
	     if(submit_time = default(submit_time), "", submit_time) as submit_time,
	     if(start_time = default(start_time), "", start_time) as start_time,
	     if(finish_time = default(finish_time), "", finish_time) as finish_time,
	     IF(finish_time != DEFAULT(finish_time) AND start_time != DEFAULT(start_time), timediff(finish_time, start_time), '') as elap,
	     t.output_path, t.output_file, t.params,
	     t.req_memory, t.req_cpu, t.req_runtime, t.user_metadata,
	     cj.job_id, cj.job_status, cj.maxrss, cj.cluster_id, cj.nodelist, te.active
	     $full_condition
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
 { title => "Cl stat"},
 { title => "CPU", align => 'r' },
 { title => "Req RAM" },
 { title => "Req Time", convert => \&parse_duration, align => 'r' },
 { title => "Nodes" },
 { title => "RAM used", align => 'r' },
     );

if ($opt->genome_id)
{
    push(@cols, { title => "Genome ID" });
    push(@cols, { title => "Indexing skipped" });
}

if ($opt->show_times)
{
    push(@cols, { title => "Start time" });
    push(@cols, { title => "Finish time" });
}

if ($opt->show_output_file)
{
    push(@cols, { title => "Output file" });
}

if ($opt->show_output_path)
{
    push(@cols, { title => "Output path" });
}

if ($opt->show_user_metadata)
{
    push(@cols, { title => "User metadata" });
}

if ($opt->show_inactive_jobs)
{
    push(@cols, { title => "Cjob active" });
}

push(@cols, map { { title => $_ } } @{$opt->show_parameter});
push(@cols, map { { title => $_ } } @{$opt->show_count});

if ($opt->show_all_parameters)
{
    push(@cols, { title => "Params" });
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

    my $decoded_params = eval { decode_json($task->{params}); } // {};

    $task->{task_state} = $task_state_info->{$task->{state_code}}->{description};
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
	$indexing_skipped = $decoded_params->{skip_indexing} ? 1 : 0;
    }

    (my $owner = $task->{owner}) =~ s/\@patricbrc.org$//;

    $task->{task_state} =~ s/Submitted.*/Sub/;
    $task->{task_state} =~ s/Complete.*/Comp/;
    my $elapsed = $task->{elap};
    if ($opt->elapsed_seconds)
    {
	if ($elapsed =~ /^(\d{2,34}):(\d\d):(\d\d)$/)
	{
	    $elapsed = $1 * 3600 + $2 * 60 + $3;
	}
    }
    
    my @row = ($task->{task_id}, $task->{task_state}, $owner, $task->{application_id},
	      $task->{submit_time}, $elapsed,
	      $task->{job_id} ? ($task->{cluster_id}, $task->{job_id}, $task->{job_status},
				 $task->{req_cpu}, $task->{req_memory}, $task->{req_runtime},
				 $task->{nodelist}, int($task->{maxrss})) : ());
    push(@row, $genome_id, $indexing_skipped) if $opt->genome_id;
    push(@row, $task->{start_time}) if $opt->show_times;
    push(@row, $task->{finish_time}) if $opt->show_times;
    push(@row, $task->{output_file}) if $opt->show_output_file;
    push(@row, $task->{output_path}) if $opt->show_output_path;
    push(@row, $task->{user_metadata}) if $opt->show_user_metadata;
    push(@row, $task->{active}) if $opt->show_inactive_jobs;

    for my $p (@{$opt->show_parameter})
    {
	my $val = $decoded_params->{$p};
	if (ref($val))
	{
	    $val = encode_json($val);
	}
	push(@row, $val);
    }
    for my $p (@{$opt->show_count})
    {
	my $val = $decoded_params->{$p};
	if (ref($val) eq 'ARRAY')
	{
	    $val = @$val;
	}
	else
	{
	    $val = '';
	}
	push(@row, $val);
    }
    if ($opt->show_all_parameters)
    {
	push(@row, encode_json($decoded_params));
    }
	 

    for my $i (0..$#cols)
    {
	my $col = $cols[$i];
	if ($col->{convert})
	{
	    $row[$i] = $col->{convert}($row[$i]);
	}
    }
			  

    push(@rows, \@row);

    if ($opt->parsable)
    {
	say join("\t", @row);
    }
}

#print $tbl;

if (!$opt->parsable)
{
    my @aligns = map { $_->{align} // 'l' } @cols;
    say generate_table(rows => \@rows, header_row => 1, align => \@aligns);
}

sub parse_duration {
    use integer;
    my($t) = @_;
    my $d = $t / 86400;
    $t = $t % 86400;
    my $res;
    $res = "${d}d-" if $d;
    $res .= sprintf("%02d:%02d:%02d", $t/3600, $t/60%60, $t%60);
    return $res;
}
