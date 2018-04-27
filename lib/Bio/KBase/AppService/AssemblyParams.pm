#
# Wrap up logic for intrepreting assembly service parameters
# and for handling staging.
#
# We pulled this out of the app so we can reuse the validation
# for the purpose of validating for the comprehensive analysis application.
#

package Bio::KBase::AppService::AssemblyParams;

use strict;
use Data::Dumper;

=head1 Assembly Service Parameters

The AssemblyParams module encapsulates the parsing and validation of
input to the assembly service.

It is initialized from the app service parameters structure:

    my $ap = Bio::KBase::AppService::AssemblyParams->new($params)

=cut

use base 'Class::Accessor';
__PACKAGE__->mk_accessors(qw(params single_end_libs paired_end_libs interleaved_libs));

sub new
{
    my($class, $params) = @_;

    my $self = {
	params => $params,
	single_end_libs => [],
	paired_end_libs => [],
	interleaved_libs => []
    };

    bless $self, $class;
    $self->parse_single_end_libs();
    $self->parse_paired_end_libs();
    # $self->parse_srr_ids();
    # $self->parse_settings();
    
    return $self;
}

sub extract_params
{
    my($self) = @_;

    my $res = {};

    for my $p (qw(paired_end_libs single_end_libs srr_ids
		  reference_assembly recipe pipeline
		  min_contig_len min_contig_cov))
    {
	$res->{$p} = $self->params->{$p} if exists $self->params->{$p};
    }
    return $res;
}

sub parse_single_end_libs
{
    my($self) = @_;
    for my $lib (@{$self->params->{single_end_libs}})
    {
	my($read_file, $platform) = @$lib{'read', 'platform'};
	#
	# Manually use defaults from spec file.
	#
	$platform //= 'infer';
	$read_file or die "Input parameter error: single end read library missing a read file\n";
	my $selib = SingleEndLibrary->new($self, $read_file, $platform);
	push(@{$self->single_end_libs}, $selib);
    }
}

sub parse_paired_end_libs
{
    my($self) = @_;
    for my $lib (@{$self->params->{paired_end_libs}})
    {
	my($read1, $read2, $platform, $interleaved) = @$lib{qw(read1 read2 platform interleaved)};
	my $paired_params = PairingParams->new($lib);
	#
	# Manually use defaults from spec file.
	#
	$platform //= 'infer';
	$read1 or die "Input parameter error: single end read library missing a read file\n";

	my $pelib;
	if ($interleaved)
	{
	    if ($read2)
	    {
		die "Input parameter error: interleaved library should not define read2";
	    }
	    $pelib = InterleavedLibrary->new($self, $read1, $platform, $paired_params);
	    push(@{$self->interleaved_libs}, $pelib);
	}
	else
	{
	    if (!$read2)
	    {
		die "Input parameter error: paired end library missing read2";
	    }

	    $pelib = PairedEndLibrary->new($self, $read1, $read2, $platform, $paired_params);
	    push(@{$self->paired_end_libs}, $pelib);
	}
    }
}

package PairingParams;
use strict;
sub new
{
    my($class, $lib) = @_;

    my $self = {
	read_orientation_outward => 0,
	insert_size_mean => undef,
	insert_size_stdev => undef,
    };

    
    for my $param (qw(read_orientation_outward insert_size_mean insert_size_stdev ))
    {
	$self->{param} = $lib->{param} if $lib->{param};
    }
    
    return bless $self, $class;
}


package SingleEndLibrary;

use strict;

sub new
{
    my($class, $assembly_params, $read_file, $platform) = @_;

    my $self = {
	assembly_params => $assembly_params,
	read_file => $read_file,
    };
    return bless $self, $class;
}

package PairedEndLibrary;

use strict;

sub new
{
    my($class, $assembly_params, $read1, $read2, $platform, $pairing_params) = @_;

    my $self = {
	assembly_params => $assembly_params,
	read_file_1 => $read1,
	read_file_2 => $read2,
	platform => $platform,
	pairing_params => $pairing_params,
    };
    return bless $self, $class;
}

package InterleavedLibrary;

use strict;

sub new
{
    my($class, $assembly_params, $read_file, $platform, $pairing_params) = @_;

    my $self = {
	assembly_params => $assembly_params,
	read_file => $read_file,
	pairing_params => $pairing_params,
	platform => $platform,
    };
    return bless $self, $class;
}


1;
