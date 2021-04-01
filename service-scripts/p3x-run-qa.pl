#
# Run one or more QA tests. Assume user is in an App-Appname directory
#

use strict;
use POSIX;
use Data::Dumper;
use Getopt::Long::Descriptive;
use File::Path qw(make_path);
use File::Basename;
use JSON::XS;
use IPC::Run qw(run);
use Cwd qw(getcwd abs_path);
use File::Slurp;
use File::Temp;

my $json = JSON::XS->new->pretty(1)->canonical(1);

my($opt, $usage) = describe_options("%c %o [test-params.json]",
				    ["container|c=s" => "Container id to run with"],
				    ["submit|s" => "Submit the job to the scheduler"],
				    ["base|b=s" => "Use this directory as the deployment base for the run (not for use with --submit)"],
				    ["app|a=s" => "Application name"],
				    ["user-metadata=s" => "User metadata for this run"],
				    ["reservation=s" => "Use this reservation for job submission"],
				    ['override=s@' => "Override other parameter settings in app parameter file", { default => [] }],
				    ["out|o=s" => "Use this workspace path as the output base",
				 { default => '/olson@patricbrc.org/PATRIC-QA/applications' }],
				    ["meta-out=s" => "Write metadata from this submission to this file."],
				    ["help|h" => "Show this help message"],
				   );
$usage->die() if @ARGV > 1;
print($usage->text), exit 0 if $opt->help;

my $hostname = `hostname`;
chomp $hostname;
my $here = getcwd;
my @container_paths = qw(/disks/patric-common/container-cache /vol/patric3/production/containers);

my $tmp = "$here/tmp";
make_path($tmp);
$ENV{TMPDIR} = $tmp;

#
# Determine deployment base.
#
my $base = $opt->base;
my @specs_dirs;
if (!$base)
{
    $base = $ENV{KB_TOP};
    #
    # Need specs dir.
    #
    my $specs = "$base/services/app_service/app_specs";
    if (-d $specs)
    {
	@specs_dirs = ($specs);
    }
    else
    {
	#
	# In a dev container. Enumerate them.
	#
	@specs_dirs = glob("$base/modules/*/app_specs");
    }
}


my $app = $opt->app;
if (!defined($app))
{
    if ($here =~ m,/App-(\S+?)($|/),)
    {
	$app = $1;
    }
    else
    {
	die "Application not found for run in directory $here\n";
    }
}

#
# Find our app spec.
#
my $app_spec;
if (!$opt->submit)
{
    for my $path (@specs_dirs)
    {
	my $s = "$path/$app.json";
	if (-s $s)
	{
	    $app_spec = $s;
	    last;
	}
    }
    $app_spec or die "Could not find app spec for $app\n";
}

my @bindings = ("/disks/tmp:/tmp",
		$here,
		"/opt/patric-data-2020-0914a:/opt/patric-common/data",
		);

my @input;
if (@ARGV > 0)
{
    my $inp = shift;
    $inp = abs_path($inp);
    push(@bindings, dirname($inp));
    
    push(@input, $inp);
}
else
{
    for my $inp (sort { $a cmp $b } glob("tests/*.json"))
    {
	push(@input, abs_path($inp));
    }
}

#
# We set up an output directory based on the current date
# and time and the name of the input file.
#

my $app_name = "App-$app";

my $now = time;
my $output_base = strftime("%Y/%m/%d/%H-%M-%S", localtime $now);
my $output_path = $opt->out . "/$app_name/$output_base";
my $output_file = strftime("out.%Y-%m-%d-%H-%M-%S", localtime $now);

#
# For each of our input files, rewrite input json to have the changed output location.
#

my @to_run;
for my $input (@input)
{
    push @to_run, rewrite_input($input, $opt, $output_path, $output_file);
}

#
# Now we may execute. If we are using cluster submission, use appserv-start-app. Otherwise
# we will start at command line, optionally within a container.
#
for my $dat (@to_run)
{
    if ($opt->submit)
    {
	submit_job($app, $dat, $opt->container);
    }
    elsif ($opt->container)
    {
	run_in_container($app, $app_spec, $dat, $opt->container);
    }
    else
    {
	run_locally($app, $app_spec, $dat);
    }
}

sub run_in_container
{
    my($app, $spec, $dat, $container_id) = @_;

    my($params, $out_dir, $output_path, $output_file) = @$dat;

    #
    # Find our container.
    #
    my $container;
    for my $p (@container_paths)
    {
	my $c = "$p/$container_id.sif";
	if (-s $c)
	{
	    $container = $c;
	}
    }
    $container or die "Cannot find container $container_id in @container_paths\n";

    my $bindings = join(",", @bindings);
    
    my @cmd = ("singularity", "exec", "--env", "KB_INTERACTIVE=1", "-B", $bindings, $container, "App-$app", "xx", $spec, $params);
    print "Run @cmd\n";
    my $ok = run(\@cmd,
		 '>', "$out_dir/stdout.log",
		 '2>', "$out_dir/stderr.log",
		);
    my $exitcode = $?;
    write_file("$out_dir/exitcode", "$exitcode\n");
    write_file("$out_dir/hostname", "$hostname\n");
    write_file("$out_dir/user_metadata", $opt->user_metadata) if $opt->user_metadata;

    if ($opt->meta_out)
    {
	write_file($opt->meta_out, $json->encode({ exitcode => $exitcode,
						       app => $app,
						       hostname => $hostname,
						       fs_dir => $out_dir,
						       output_path => $output_path,
						       output_file => $output_file,
						   }));
    }
    $ok or die "Error running @cmd\n";
	       
}

sub run_locally
{
    my($app, $spec, $dat) = @_;
    my($params, $out_dir, $output_path, $output_file) = @$dat;

    #
    # We need to submit the run with an environment configured
    # with the current properly if $base was set. Ignore this for now.
    #

    my @cmd = ("App-$app", "xx", $spec, $params);
    print "Run @cmd\n";
    my $ok = run(\@cmd,
		 init => sub { $ENV{KB_INTERACTIVE} = 1 },
		 '>', "$out_dir/stdout.log",
		 '2>', "$out_dir/stderr.log",
		);
    my $exitcode = $?;
    write_file("$out_dir/exitcode", "$exitcode\n");
    write_file("$out_dir/hostname", "$hostname\n");
    write_file("$out_dir/user_metadata", $opt->user_metadata) if $opt->user_metadata;
    if ($opt->meta_out)
    {
	write_file($opt->meta_out, $json->encode({ exitcode => $exitcode,
						       app => $app,
						       hostname => $hostname,
						       fs_dir => $out_dir,
						       output_path => $output_path,
						       output_file => $output_file,
						   }));
    }
    $ok or die "Error running @cmd\n";
	       
}

sub submit_job
{
    my($app, $dat, $container) = @_;
    my($params, $out_dir, $output_path, $output_file) = @$dat;

    my @cmd = ('appserv-start-app');
    push(@cmd, '-c', $container) if $container;
    push(@cmd, '--reservation', $opt->reservation) if $opt->reservation;
    push(@cmd, "--user-metadata", $opt->user_metadata) if $opt->user_metadata;
    push(@cmd, $app, $params);

    my $out;
    my $ok = run(\@cmd, ">", \$out);
    my $exitcode = $?;
    print $out;
    my $task_id;
    if ($out =~ /Started\s+task\s+(\d+)/)
    {
	$task_id = $1;
	write_file("$out_dir/task_id", "$task_id\n");
    }
    my @bad;
    if (!$ok)
    {
	@bad = (exitcode => $exitcode, hostname => 'none');
    }
    if ($opt->meta_out)
    {
	write_file($opt->meta_out, $json->encode({ task_id => $task_id,
						       app => $app,
						       fs_dir => $out_dir,
						       output_path => $output_path,
						       output_file => $output_file,
						       @bad
						   }));
    }
    $ok or die "Error running @cmd\n";
}


sub rewrite_input
{
    my($input, $opt,  $output_path, $output_file) = @_;
    
    my $params = $json->decode(scalar read_file($input));

    my $this_base = join("/", $output_path, basename($input));

    if ($params->{output_path} && $this_base)
    {
	# print STDERR "Change output path from $params->{output_path} to " . $this_base . "\n";
	$params->{output_path} = $this_base;
    }
    
    if ($params->{output_file} && $output_file)
    {
	# print STDERR "Change output file from $params->{output_file} to " . $output_file . "\n";
	$params->{output_file} = $output_file;
    }

    for my $ent (@{$opt->override})
    {
	my($k, $v) = split(/=/, $ent, 2);
	$params->{$k} = $v;
    }

    #
    # if we are running locally or in a container, define output path
    #

    my $out_dir = join("/", $here, strftime("%Y/%m/%d/%H-%M-%S", localtime $now), basename($input));
    make_path($out_dir);
    my $params_file = "$out_dir/" . basename($input);
    write_file($params_file, $json->encode($params));
    return [$params_file, $out_dir, $this_base, $output_file];
}
