
#
# Module to encapsulate metagenome binning code.
#
# Name badness. app_params used in two different ways down there. Fix that.
#

package Bio::KBase::AppService::MetagenomeBinning;

use P3DataAPI;
use gjoseqlib;
use strict;
use Data::Dumper;
use Cwd;
use base 'Class::Accessor';
use JSON::XS;
use Bio::KBase::AppService::Client;
use Bio::KBase::AppService::AppConfig qw(data_api_url db_host db_user db_pass db_name
					 seedtk binning_genome_annotation_clientgroup);
use DBI;

__PACKAGE__->mk_accessors(qw(app app_def params token
			     work_dir assembly_dir stage_dir
			     output_base output_folder 
			     assembly_params spades
			     contigs app_params
			    ));

sub new
{
    my($class) = @_;

    my $self = {
	assembly_params => [],
	app_params => [],
    };
    return bless $self, $class;
}

sub process
{
    my($self, $app, $app_def, $raw_params, $params) = @_;

    $self->app($app);
    $self->app_def($app_def);
    $self->params($params);
    $self->token($app->token);

    print "Process metagenome binning run ", Dumper($app_def, $raw_params, $params);

    my $cwd = getcwd();
    my $assembly_dir = "$cwd/assembly";
    my $work_dir = "$cwd/work";
    my $stage_dir = "$cwd/stage";
    
    -d $work_dir or mkdir $work_dir or die "Cannot mkdir $work_dir: $!";
    -d $assembly_dir or mkdir $assembly_dir or die "Cannot mkdir $assembly_dir: $!";
    -d $stage_dir or mkdir $stage_dir or die "Cannot mkdir $stage_dir: $!";

    $self->work_dir($work_dir);
    $self->assembly_dir($assembly_dir);
    $self->stage_dir($stage_dir);

    my $output_base = $self->params->{output_file};
    my $output_folder = $self->app->result_folder();

    $self->output_base($output_base);
    $self->output_folder($output_folder);

    #
    # Check for exactly one of our input types;
    my @input = grep { $_ } @$params{qw(paired_end_libs contigs srr_ids)};
    if (@input == 0)
    {
	die "No input data specified";
    }
    elsif (@input > 1)
    {
	die "Only one input data item may be specified";
    }

    if (my $val = $params->{paired_end_libs})
    {
	$self->stage_paired_end_libs($val);
	$self->assemble();
    }
    elsif (my $val = $params->{srr_ids})
    {
	$self->stage_srr_ids($val);
	$self->assemble();
    }
    else
    {
	$self->stage_contigs($params->{contigs});
    }

    $self->compute_coverage();
    $self->compute_bins();
    $self->extract_fasta();
    $self->submit_annotations();
}

#
# Stage the paired end library data as given in parameters. Ensure we
# have a single pair of contigs (spades metagenome assembler only
# handles one pair of paired-end read sets).
#
# 'paired_end_libs' => [
#		                                        '/olson@patricbrc.org/Binning/Data/SRR2188006_1.fastq.gz',
#		                                        '/olson@patricbrc.org/Binning/Data/SRR2188006_2.fastq.gz'
#		                                      ],
    

sub stage_paired_end_libs
{
    my($self, $libs) = @_;

    my @reads;

    #
    # Check for new form
    #

    if (@$libs == 2 && !ref($libs->[0]) && !ref($libs->[1]))
    {
	@reads = @$libs;
    }
    else
    {
	if (@$libs == 0)
	{
	    die "MetagenomeBinning:: stage_paired_end_libs - no libs provided";
	}
	elsif (@$libs > 1)
	{
	    die "MetagenomeBinning:: stage_paired_end_libs - only one lib may be provided";
	}

	my $lib = $libs->[0];
	@reads = @$lib{qw(read1 read2)};
    }
    my $staged = $self->app->stage_in(\@reads, $self->stage_dir, 1);

    push(@{$self->assembly_params},
	 "-1", $staged->{$reads[0]},
	 "-2", $staged->{$reads[1]});
}

#
# Stage the assembled contigs.
#
sub stage_contigs
{
    my($self, $contigs) = @_;

    my $staged = $self->app->stage_in([$contigs], $self->stage_dir, 1);

    my $file = $staged->{$contigs};
    if (my($unzipped) = $file =~ /(.*)\.gz$/)
    {
	print STDERR "Unzipping $file => $unzipped\n";
	my $rc = system("gunzip", $file);
	if ($rc != 0)
	{
	    die "Error unzipping $file: $rc\n";
	}
	elsif (-s $unzipped)
	{
	    $self->contigs($unzipped);
	}
	else
	{
	    die "Zero-length file $unzipped resulting from unzipping $file\n";
	}
    }
    else
    {
	$self->contigs($staged->{$contigs});
    }
}

#
# Invoke the assembler. We've built a list of assembler parameters during
# the stage-in process. Complete the set of parameters for our
# current configuration and run the assembly.
#
sub assemble
{
    my ($self) = @_;

    my $params = $self->assembly_params;
    push(@$params,
	 "--meta",
	 "-o", $self->assembly_dir);
    my @cmd = ($self->spades, @$params);
    my $rc = system(@cmd);
    #my $rc = 0;
    if ($rc != 0)
    {
	die "Error running assembly command: @cmd\n";
    }

    $self->app->workspace->save_file_to_file($self->assembly_dir . "/contigs.fasta", {},
					     $self->output_folder . "/contigs.fasta", 'contigs', 1, 1, $self->token);
    $self->app->workspace->save_file_to_file($self->assembly_dir . "/spades.log", {},
					     $self->output_folder . "/spades.log", 'txt', 1, 1, $self->token);
    $self->app->workspace->save_file_to_file($self->assembly_dir . "/params.txt", {},
					     $self->output_folder . "/params.txt", 'txt', 1, 1, $self->token);

    $self->contigs($self->assembly_dir . "/contigs.fasta");
}

#
# Use bins_coverage to compute coverage. This has a side effect of
# copying the input fasta data to the work directory.
sub compute_coverage
{
    my($self) = @_;

    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";

    my @cmd = ("bins_coverage",
	       "--statistics-file", "coverage.stats.txt",
	       $self->contigs, $self->work_dir);
    my $rc = system(@cmd);

    $rc == 0 or die "Error $rc running coverage: @cmd";
	
    $self->app->workspace->save_file_to_file("coverage.stats.txt", {},
					     $self->output_folder . "/coverage.stats.txt", 'txt', 1, 1, $self->token);
}

sub compute_bins
{
    my($self) = @_;

    local $ENV{PATH} = seedtk . "/bin:$ENV{PATH}";

    my @cmd = ("bins_generate",
	       "--species",
	       "--statistics-file", "bins.stats.txt",
	       $self->work_dir);
    my $rc = system(@cmd);

    $rc == 0 or die "Error $rc computing bins: @cmd";
	
    $self->app->workspace->save_file_to_file("bins.stats.txt", {},
					     $self->output_folder . "/bins.stats.txt", 'txt', 1, 1, $self->token);
}

sub extract_fasta
{
    my($self) = @_;

    #my @cmd = ("bins_fasta", $self->work_dir);
    #my $rc = system(@cmd);
    # $rc == 0 or die "Error $rc computing bins: @cmd";

    #
    # We essentially inline the bins_fasta code here since we want
    # to extract the metadata from the bins.json file as we go.
    #

    local $/ = "//\n";
    open(BINS, "<", $self->work_dir . "/bins.json") or die "Cannot open " . $self->work_dir . "/bins.json: $!" ;
    open(SAMPLE, "<", $self->work_dir . "/sample.fasta") or die "Cannot open " . $self->work_dir . "/sample.fasta: $!" ;

    #
    # App params exemplar for annotation submission
    #
    # {
    # "contigs": "/olson@patricbrc.org/home/buchnera.fa",
    #     "scientific_name": "Buchnera aphidicola",
    #     "code": 11,
    #     "domain": "Bacteria",
    #     "taxonomy_id": 107806,
    #     "output_path": "/olson@patricbrc.org/home/output",
    #     "output_file": "buch32"
    #     }

    my $app_list = $self->app_params;

    my $api = P3DataAPI->new();

    my $idx = 1;

    my $all_bins = [];
    while (defined(my $bin_txt = <BINS>))
    {
	chomp $bin_txt;
	my $bin;
	eval { $bin = decode_json($bin_txt); };
	if ($@)
	{
	    warn "Bad parse on '$bin_txt'\n";
	    last;
	}
	push(@$all_bins, $bin);

	my $taxon_id = $bin->{taxonID};
	print "$bin->{name} $taxon_id\n";
	my %want;
	$want{$_} = 1 foreach @{$bin->{contigs}};

	my $bin_base_name = "bin.$idx.$taxon_id";
	my $bin_name = "$bin_base_name.fa";
	$bin->{binFastaFile} = $bin_name;
	$bin->{binIndex} = $idx;
	$idx++;
	my $bin_fa = $self->work_dir . "/$bin_name";
	open(BIN, ">", $bin_fa) or die "Cannot write $bin_fa: $!";
	seek(SAMPLE, 0, 0);

	local $/ = "\n";
	while (my($id, $def, $seq) = read_next_fasta_seq(\*SAMPLE))
	{
	    if ($want{$id})
	    {
		write_fasta(\*BIN, [[$id, $def, $seq]]);
	    }
	}
	close(BIN);

	my $ws_path = $self->output_folder . "/$bin_name";
	$self->app->workspace->save_file_to_file($bin_fa, $bin, $ws_path, 'contigs', 1, 1, $self->token);
	$bin->{binFastaPath} = $ws_path;

	my $code = 11;
	my $domain = 'Bacteria';
	my @res = $api->query("taxonomy", ["eq", 'taxon_id', $taxon_id], ["select", "genetic_code,lineage_names"]);
	if (@res)
	{
	    my $lineage;
	    ($code, $lineage) = @{$res[0]}{'genetic_code', 'lineage_names'};
	    shift @$lineage if ($lineage->[0] =~ /cellular organisms/);
	    $domain = $lineage->[0];
	}

	$bin->{domain} = $domain;
	$bin->{geneticCode} = $code;

	my $descr = {
	    contigs => $ws_path,
	    code => $code,
	    domain => $domain,
	    scientific_name=> $bin->{name},
	    taxonomy_id => $taxon_id,
	    output_path => $self->output_folder,
#	    output_path => $self->params->{output_path},
	    output_file => $bin_base_name,
	    _parent_job => $self->app->task_id,
	    analyze_quality => 1,
	    (binning_genome_annotation_clientgroup ? (_clientgroup => binning_genome_annotation_clientgroup) : ()),
	};
	push(@$app_list, $descr);
    }
    my $json = JSON::XS->new->pretty(1)->canonical(1);
    $self->app->workspace->save_data_to_file($json->encode($all_bins), {},
					     $self->output_folder . '/bins.json', 'json', 1, 1, $self->token);
    print "SAVE to " . $self->output_folder . "/bins.json\n";

    close(SAMPLE);
    close(BINS);
    print Dumper($self->app_params);
}
    
sub write_db_record
{
    my($self, $n_children) = @_;
    
    my $dsn = "DBI:mysql:database=" . db_name . ";host=" . db_host;
    my $dbh = DBI->connect($dsn, db_user, db_pass, { RaiseError => 1, AutoCommit => 0 });

    my $json = JSON::XS->new->pretty(1)->canonical(1);

    $dbh->do(qq(INSERT INTO JobGroup (parent_job, children_created, parent_app, app_spec, app_params)
		VALUES (?, ?, ?, ?, ?)), undef,
	     $self->app->task_id, $n_children, "MetagenomeBinning",
	     $json->encode($self->app_def), $json->encode($self->params));
    $dbh->commit();
}

sub submit_annotations
{
    my($self) = @_;

    $self->write_db_record(scalar @{$self->app_params});
    
    my $client = Bio::KBase::AppService::Client->new();
    for my $task (@{$self->app_params})
    {
	my $submitted = $client->start_app("GenomeAnnotation", $task, $self->output_folder);
	print Dumper($task, $submitted);
    }
}
    

1;
