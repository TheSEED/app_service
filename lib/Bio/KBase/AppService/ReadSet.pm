package Bio::KBase::AppService::ReadSet;

use strict;
use base 'Class::Accessor';
use File::Basename;

use Data::Dumper;

__PACKAGE__->mk_accessors(qw());

=head1 NAME

Bio::KBase::AppService::ReadSet

=head1 SYNOPSIS

    $readset = Bio::KBase::AppService::ReadSet->create_from_asssembly_params($params)

=head1 DESCRIPTION

A ReadSet represents a set of read libraries. It may be created from a parameter hash as
defined by the GenomeAssembly application.

=cut

sub create_from_asssembly_params
{
    my($class, $params) = @_;

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

    my $self = {
	libraries => \@libs,
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
duplicate names, a second path will disambiguate them.

=cut

sub localize_libraries
{
    my($self, $local_path) = @_;

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
    print Dumper($self);
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

    for my $lib (@{$self->libraries})
    {
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
	}

    }
    return(@errs == 0, \@errs);
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

print Dumper($self, \@illumina, \@iontorrent);

    if (@illumina && @iontorrent)
    {
	die "Invalid readset: cannot have both illumina and iontorrent reads";
    }
    push(@cmd, "--illumina", map { $_->format_paths() } @illumina) if @illumina;
    push(@cmd, "--iontorrent", map { $_->format_paths() } @iontorrent) if @iontorrent;

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

package PairedEndLibrary;
use base 'ReadLibrary';
use strict;

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

1;
