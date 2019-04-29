package Bio::KBase::AppService::ReadSet;

use strict;
use base 'Class::Accessor';
use File::Basename;
use File::Path 'make_path';
use File::Slurp;
use JSON::XS;
use IPC::Run;

use Data::Dumper;

__PACKAGE__->mk_accessors(qw());

=head1 NAME

Bio::KBase::AppService::ReadSet

=head1 SYNOPSIS

    $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params, $expand_sra)

=head1 DESCRIPTION

A ReadSet represents a set of read libraries. It may be created from a parameter hash as
defined by the GenomeAssembly application.

If the C<$expand_sra> parameter is set to a true value, then any srr_id libraries will
be expanded to add the appropriate paired end and single end libraries to the read set.
During the localize step, they will be retrieved from SRA if possible.

=cut

sub create_from_asssembly_params
{
    my($class, $params, $expand_sra) = @_;

    my @libs;

    for my $pe (@{$params->{paired_end_libs}})
    {
	my($r1, $r2, $platform, $interleaved) = @$pe{qw(read1 read2 platform interleaved)};

	if ($interleaved)
	{
	    push(@libs, InterleavedLibrary->new($r1, $platform));
	}
	else
	{
	    push(@libs, PairedEndLibrary->new($r1, $r2, $platform));
	}
    }
    for my $se (@{$params->{single_end_libs}})
    {
	my($read, $platform) = @$se{qw(read platform)};
	push(@libs, SingleEndLibrary->new($read, $platform));
    }
    for my $srr (@{$params->{srr_ids}})
    {
	push(@libs, SRRLibrary->new($srr));
    }

    my $self = {
	libraries => \@libs,
	expand_sra => ($expand_sra ? 1 : 0),
	validated => 0,
    };
    return bless $self, $class;
}

=head2 METHODS

=over 4

=item B<localize_libraries>

    $readset->localize_libraries($local_path)

For each library in the set, create a local path field constructed
from the C<$local_path> parameter and the basename of the library. 

If necessary this process will squash spaces and other troublesome
characters. If after the localization process is complete we have
duplicate names, a second pass will disambiguate them.

=cut

sub localize_libraries
{
    my($self, $local_path) = @_;

    $self->{local_path} = $local_path;
    if ($self->{expand_sra})
    {
	$self->expand_sra_metadata();
    }

    my %names;

    for my $lib (@{$self->libraries})
    {
	for my $fk ($lib->file_keys())
	{
	    my $file = $lib->{$fk};
	    my $base = basename($file);
	    $base =~ s/[^.\w]/_/g;
	    my $ent= [$file, $base, $lib, $fk];
	    push (@$ent, $ent);
	    push(@{$names{$base}}, $ent);
	}
    }

    for my $name (keys %names)
    {
	# print "\nProc $name\n";
	my $list = $names{$name};
	if (@$list > 1)
	{
	    # must disambiguate
	    # first check for sets of files that have the same path
	    my %by_path;
	    for my $l (@$list)
	    {
		push(@{$by_path{$l->[0]}}, $l);
	    }
	    my @paths = keys %by_path;
	    if (@paths < 2)
	    {
	    	# multiple occurrences of same file. Don't need to change.
		next;
	    }
	    my $disambig_idx = 1;
	    # print Dumper(\@paths, \%by_path);
	    for my $path (@paths)
	    {
		for my $ent (@{$by_path{$path}})
		{
		    my($file, $base, $lib, $fk, $entref) = @$ent;
		    print "Disambig $disambig_idx '$file' '$base' '$lib' '$fk'\n";
		    $entref->[1] = "$disambig_idx-$entref->[1]";
		}
		$disambig_idx++;
	    }

	}
    }

    #
    # Update names.
    #
    while (my($name, $list) = each %names)
    {
	for my $ent (@$list)
	{
	    my($file, $base, $lib, $fk) = @$ent;
	    my $old = $lib->{$fk};
	    my $nk = $fk;
	    $nk =~ s/read_file/read_path/;
	    $lib->{$nk} = "$local_path/$base";
	}
    }
    #die Dumper($self);
}

=item B<validate>

    ($ok, $errors) = $readset->validate($ws);

Validate this readset.

Walk the read files and ensure that the files exist in the 
workspace and are not zero sized.

=cut

sub validate
{
    my($self, $ws) = @_;

    my @errs;

    my $total_comp_size;
    my $total_uncomp_size;

    for my $lib (@{$self->libraries})
    {
	#
	# SRR is a special case; we will need to pull metadata.
	#

	if ($lib->isa('SRRLibrary'))
	{
	    my $tmp = File::Temp->new();
	    close($tmp);
	    my $rc = system("p3-sra", "--metaonly", "--metadata-file", "$tmp", "--id", $lib->{id});
	    if ($rc != 0)
	    {
		push(@errs, "p3-sra failed: $rc");
	    }
	    else
	    {
		my $mtxt = read_file("$tmp");
		my $meta = eval { decode_json($mtxt); };
		$meta or die "Error loading or evaluating json metadata: $mtxt";
		print Dumper(MD => $meta);
		my($me) = grep { $_->{accession} eq $lib->{id} } @$meta;
		$total_comp_size += $me->{size};
		$lib->{metadata} = $me;
	    }
	    next;
	}

	my @files = $lib->files();
	for my $f (@files)
	{
	    my $s = $ws->stat($f);

	    if (!$s)
	    {
		push(@errs, "File $f does not exist");
	    }
	    elsif ($s->size == 0)
	    {
		push(@errs, "File $f has zero size");
	    }
	    else
	    {
		if ($ws->file_is_gzipped($f))
		{
		    $total_comp_size += $s->size;
		} else {
		    $total_uncomp_size += $s->size;
		}
	    }
	}

    }
    $self->{validated} = (@errs == 0);
    return(@errs == 0, \@errs, $total_comp_size, $total_uncomp_size);
}

=item B<expand_sra_metadata>

    $readset->expand_sra_metadata()

For each SRA library in the readset, use C<p3-sra> to look up the 
library metadata and add the appropriate read library to the readset.

=cut

sub expand_sra_metadata
{
    my($self) = @_;

    $self->visit_libraries(undef, undef, sub { $self->expand_one_sra_metadata($_[0]); });
}

sub expand_one_sra_metadata
{
    my($self, $lib) = @_;

    my $md = $lib->{metadata};

    if ($md->{n_reads} ==2 || $md->{library_layout} eq 'PAIRED')
    {
	my $fn1 = "$md->{accession}_1.fastq";
	my $fn2 = "$md->{accession}_2.fastq";
	my $nlib = PairedEndLibrary->new($fn1, $fn2);
	$nlib->{derived_from} = $lib;
	$lib->{derives} = $nlib;
	push(@{$self->{libraries}}, $nlib);
    }
    elsif ($md->{n_reads} == 1 || $md->{library_layout} eq 'SINGLE')
    {
	my $fn1 = "$md->{accession}.fastq";
	my $nlib = SingleEndLibrary->new($fn1);
	$nlib->{derived_from} = $lib;
	$lib->{derives} = $nlib;
	push(@{$self->{libraries}}, $nlib);
    }
    else
    {
	warn "Cannot parse metadata for read count; defaulting to paired\n" . Dumper($md);
	my $fn1 = "$md->{accession}_1.fastq";
	my $fn2 = "$md->{accession}_2.fastq";
	my $nlib = PairedEndLibrary->new($fn1, $fn2);
	$nlib->{derived_from} = $lib;
	$lib->{derives} = $nlib;
	push(@{$self->{libraries}}, $nlib);
    }
}


=item B<stage_in>

    $readset->stage_in($ws)

Given a localized read set, stage the read files into 
the local storage as defined by L<localize_libraries>.

=cut

sub stage_in
{
    my($self, $ws) = @_;

    #
    # use %done to signal having already downloaded, in the case
    # we had duplicate libraries referenced in the set
    #
    my %done;
    for my $lib (@{$self->libraries})
    {
	if ($lib->isa('SRRLibrary'))
	{
	    $self->stage_in_srr($lib);
	}
	elsif ($lib->{derived_from})
	{
	    warn "skipping derived lib " . Dumper($lib);
	}
	else
	{
	    for my $fk ($lib->file_keys)
	    {
		(my $path_key = $fk) =~ s/read_file/read_path/;
		my $file = $lib->{$fk};
		my $path = $lib->{$path_key};
		next if $done{$file,$path}++;
		
		print STDERR "Load $file to $path\n";
		$ws->download_file($file, $path, 1);
	    }
	}
    }
}

=item B<stage_in_srr>

    $readset->stage_in_srr($srr_lib)

Use p3-sra to download the data files for hte given SRA library.

=cut

sub stage_in_srr
{
    my($self, $lib) = @_;

    my $id = $lib->{id};
    my $path = "$self->{local_path}/tmp.$id";
    make_path($path);
    my @cmd = ("p3-sra", "--out", $path, "--id", $id);
    my($stdout, $stderr);
    print "@cmd\n";
    my $ok = IPC::Run::run(\@cmd, '>', \$stdout, '2>', \$stderr);
    if (!$ok)
    {
	die "Failure $? to run command @cmd: stdout:\n$stdout\nstderr:\n$stderr\n";
    }
    #
    # Look in the derived library to find the expected filenames and local paths.
    #
    my $dlib = $lib->{derives};

    eval { $dlib->copy_from_tmp($path); };
    if ($@)
    {
	#
	# SRA might have lied to us (e.g. SRR6382381 metadata is for single end,
	# but the data is paired end).
	#
	# Check for the case where the library type is incorrect. Patch around it if so,
	# and retry the copy.
	#
	my $md = $lib->{metadata};
	
	if ($dlib->isa('PairedEndLibrary'))
	{
	    # check for single-end output
	    my $fn = $md->{accession} . ".fastq";
	    if (-f "$path/$fn")
	    {
		die "Found a single end for paired end metadata\n";
	    }
	    else
	    {
		die "Couldn't resolve";
	    }
	}
	elsif ($dlib->isa('SingleEndLibrary'))
	{
	    # check for single-end output
	    my $fn1 = $md->{accession} . "_1.fastq";
	    my $fn2 = $md->{accession} . "_2.fastq";
	    if (-f "$path/$fn1" && -f "$path/$fn2")
	    {
		warn "Found a paired end for single end metadata\n";
		#
		# Remove the derived lib from the list and re-add the proper form
		#
		my $libs = $self->{libraries};
		my $index = 0;
		$index++ until $libs->[$index] eq $dlib || $index > $#$libs;
		splice(@$libs, $index, 1) if $index <= $#$libs;
		my $nlib = PairedEndLibrary->new($fn1, $fn2);
		$nlib->{derived_from} = $lib;
		$lib->{derives} = $nlib;
		push(@$libs, $nlib);
		$dlib = $nlib;
		# ick. Need to relocalize, but disable expand_sra so that
		# we don't pull the metadata again.
		local $self->{expand_sra} = 0;
		$self->localize_libraries($self->{local_path});
		$dlib->copy_from_tmp($path);
	    }
	    else
	    {
		die "Couldn't resolve";
	    }
	}
    }
}

=item B<paths>

    @paths = $readset->paths()

Return the list of paths from the library.

=cut

sub paths
{
    my($self) = @_;
    return map { $_->paths() } @{$self->libraries};
}

=item B<libraries_of_type>
    
    my @libs = $readset->libraries_of_type($type)

Return a list of the libraries of the given (p3_assembly) type.

=cut

sub libraries_of_type
{
    my($self, $type) = @_;

    return grep { $_->p3_assembly_library_type eq $type } $self->libraries;
}

=item B<visit_libraries>

    $readset->visit_libraries(\&pe_callback, \&se_callback, \&srr_callback)

Walk the readset and invoke the appropriate callback on the libraries included.

=cut

sub visit_libraries
{
    my($self, $pe_cb, $se_cb, $srr_cb) = @_;

    for my $lib ($self->libraries)
    {
	if ($lib->isa("PairedEndLibrary"))
	{
	    $pe_cb->($lib) if $pe_cb;;
	}
	elsif ($lib->isa("SingleEndLibrary"))
	{
	    $se_cb->($lib) if $se_cb;;
	}
	elsif ($lib->isa("SRRLibrary"))
	{
	    $srr_cb->($lib) if $srr_cb;
	}
	else
	{
	    die "Invalid library " . Dumper($lib);
	}
    }
}

=item B<build_p3_assembly_arguments>

    my @args = $readset->build_p3_assembly_arguments()

Specialty routine to construct the appropiate arguments for the
L<p3_assembly|https://github.com/AllanDickerman/p3_assembly/blob/master/scripts/p3_assembly.py> command.

=cut

sub build_p3_assembly_arguments
{
    my($self) = @_;

    my @cmd = ();

    my @illumina = $self->libraries_of_type('illumina');
    my @iontorrent = $self->libraries_of_type('iontorrent');
    my @sra = $self->libraries_of_type('sra');

print Dumper($self, \@illumina, \@iontorrent, \@sra);

    if (@illumina && @iontorrent)
    {
	die "Invalid readset: cannot have both illumina and iontorrent reads";
    }
    push(@cmd, "--illumina", map { $_->format_paths() } @illumina) if @illumina;
    push(@cmd, "--iontorrent", map { $_->format_paths() } @iontorrent) if @iontorrent;
    push(@cmd, "--sra", map { $_->{id} } @sra) if @sra;

    for my $pair (["anonymous", "--anonymous_reads"],
		  ["pacbio", "--pacbio"],
		  ["nanopore", "--nanopore"])
    {
	my($type, $arg) = @$pair;
	my @list = $self->libraries_of_type($type);
	push(@cmd, $arg, map { $_->format_paths() } @list) if @list;
    }
    return @cmd;
}

=item B<libraries>

    my @libs = $readset->libraries();
    my $libs = $readset->libraries();

Return the list of libraries in this readset. Return list in array context,
list ref in scalar.

=cut

sub libraries
{
    my($self) = @_;
    my $libs = $self->{libraries};
    return wantarray ? @$libs : $libs;
}

=back
   
=cut

package ReadLibrary;

use strict;
use Data::Dumper;

sub files
{
    my($self) = @_;
    return @$self{$self->file_keys()};
}
    
sub paths
{
    my($self) = @_;
    my @out;
    for my $fk ($self->file_keys)
    {
	(my $path_key = $fk) =~ s/read_file/read_path/;
	push(@out, $self->{$path_key});
    }
    return @out;
}
    
our %platform_map = ('' => 'anonymous',
		     infer => 'anonymous',
		     illumina => 'illumina',
		     pacbio => 'pacbio',
		     nanopore => 'nanopore',
		     iontorrent => 'iontorrent');

sub p3_assembly_library_type
{
    my($self) = @_;
    my $platform = $self->{platform};
    my $mp = $platform_map{$platform};
    $mp //= 'anonymous';
    return $mp;
}

package SingleEndLibrary;

use strict;
use base 'ReadLibrary';
use File::Basename;
use File::Copy 'move';

sub new
{
    my($class, $read_file, $platform) = @_;

    my $self = {
	read_file => $read_file,
	platform => $platform,
    };
    return bless $self, $class;
}

sub file_keys
{
    return qw(read_file);
}

sub format_paths
{
    my($self) = @_;
    return $self->{read_path};
}

=item B<copy_from_tmp>

    $ok = $lib->copy_from_tmp($path)

Look in $path for the filename corresponding to this library. If there, move into our
localized path. Otherwise fail.

=cut

sub copy_from_tmp
{
    my($self, $path) = @_;
    my $file = basename($self->{read_file});
    my $tfile = "$path/$file";
    if (-f $tfile)
    {
	if (!move($tfile, $self->{read_path}))
	{
	    die "copy_from_tmp: error moving $tfile => $self->{read_path}: $!";
	}
    }
    else
    {
	die "copy_from_tmp: missing file $tfile";
    }
}
    

package PairedEndLibrary;
use base 'ReadLibrary';
use strict;
use File::Basename;
use File::Copy 'move';

sub new
{
    my($class, $read1, $read2, $platform) = @_;

    my $self = {
	read_file_1 => $read1,
	read_file_2 => $read2,
	platform => $platform,
    };
    return bless $self, $class;
}

sub file_keys
{
    return qw(read_file_1 read_file_2);
}

sub format_paths
{
    my($self) = @_;

    my @p = @$self{qw(read_path_1 read_path_2)};

    # if we are anonymous, return separate items.

    if ($self->p3_assembly_library_type eq 'anonymous')
    {
	return @p;
    }
    else
    {
	return join(":", @p);
    }
}

=item B<copy_from_tmp>

    $ok = $lib->copy_from_tmp($path)

Look in $path for the filename corresponding to this library. If there, move into our
localized path. Otherwise fail.

=cut

sub copy_from_tmp
{
    my($self, $path) = @_;

    for my $suffix ('_1', '_2')
    {
	my $file = basename($self->{"read_file$suffix"});
	my $tfile = "$path/$file";
	if (-f $tfile)
	{
	    my $dest = $self->{"read_path$suffix"};
	    if (!move($tfile, $dest))
	    {
		die "copy_from_tmp: error moving $tfile => $dest: $!";
	    }
	}
	else
	{
	    die "copy_from_tmp: missing file $tfile";
	}
    }
}
    
package InterleavedLibrary;

use base 'ReadLibrary';
use strict;

sub new
{
    my($class, $read, $platform) = @_;

    my $self = {
	read_file => $read,
	platform => $platform,
    };
    return bless $self, $class;
}

sub file_keys
{
    return qw(read_file);
}

sub format_paths
{
    my($self) = @_;
    return $self->{read_path};
}

=item B<copy_from_tmp>

    $ok = $lib->copy_from_tmp($path)

Look in $path for the filename corresponding to this library. If there, move into our
localized path. Otherwise fail.

=cut

sub copy_from_tmp
{
    my($self, $path) = @_;
    my $file = basename($self->{read_file});
    my $tfile = "$path/$file";
    if (-f $tfile)
    {
	if (!move($tfile, $self->{read_path}))
	{
	    die "copy_from_tmp: error moving $tfile => $self->{read_path}: $!";
	}
    }
    else
    {
	die "copy_from_tmp: missing file $tfile";
    }
}
    
package SRRLibrary;

use base 'ReadLibrary';
use strict;

sub new
{
    my($class, $id) = @_;

    my $self = {
	id => $id,
    };
    return bless $self, $class;
}

sub p3_assembly_library_type
{
    my($self) = @_;
    return 'sra';
}

sub file_keys
{
    
}

sub format_paths
{

}

1;
