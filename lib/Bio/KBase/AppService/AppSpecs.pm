#
# Manage app-spec files.
#

package Bio::KBase::AppService::AppSpecs;

use strict;
use Data::Dumper;
use base 'Class::Accessor';
use JSON::XS;
use File::Slurp;

__PACKAGE__->mk_accessors(qw(spec_dirs));

sub new
{
    my($class, $dir) = @_;

    my $top = $ENV{KB_TOP};
    my $specs_deploy = "$top/services/app_service/app_specs";

    my @spec_dirs;
    
    if (-d $specs_deploy)
    {
	@spec_dirs = ($specs_deploy);
    }
    else
    {
	@spec_dirs = glob("$top/modules/*/app_specs");
    }

    my $self = {
	spec_dirs => \@spec_dirs,
    };
    return bless $self, $class;
}

sub enumerate
{
    my($self) = @_;

    my $dh;

    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    my @list;
    my @dirs = @{$self->spec_dirs};
    
    if (@dirs == 0)
    {
	warn "No app directories specified\n";
    }
    else
    {
	for my $dir (@dirs)
	{
	    my @files = sort { $a cmp $b } glob("$dir/*.json");
	    for my $f (@files)
	    {
		my $obj = eval { $json->decode(scalar read_file($f)) };
		if (!$obj)
		{
		    warn "Could not read $f: $@\n";
		}
		else
		{
		    push(@list, $obj);
		}
	    }
	}
    }
    return @list;
}

sub find
{
    my($self, $app_id) = @_;

    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    my @list;
    my @dirs = @{$self->spec_dirs};
    
    if (@dirs == 0)
    {
	warn "No app directories specified\n";
    }
    else
    {
	for my $dir (@dirs)
	{
	    my @files = sort { $a cmp $b } glob("$dir/*.json");
	    for my $f (@files)
	    {
		my $obj = eval { $json->decode(scalar read_file($f)) };
		if (!$obj)
		{
		    warn "Could not read $f: $@\n";
		}
		else
		{
		    if ($obj->{id} eq $app_id)
		    {
			if (wantarray)
			{
			    return ($obj, $f);
			}
			else
			{
			    return $obj;
			}
		    }
		}
	    }
	    
	}
    }
    return undef;
}

1;
