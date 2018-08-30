#
# Manage app-spec files.
#

package Bio::KBase::AppService::AppSpecs;

use strict;
use Data::Dumper;
use base 'Class::Accessor';
use JSON::XS;
use File::Slurp;

__PACKAGE__->mk_accessors(qw(dir));

sub new
{
    my($class, $dir) = @_;
    my $self = {
	dir => $dir,
    };
    return bless $self, $class;
}

sub enumerate
{
    my($self) = @_;

    my $dh;
    my $dir = $self->dir;

    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    my @list;
    
    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = sort { $a cmp $b } grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = $json->decode(scalar read_file("$dir/$f"));
	    if (!$obj)
	    {
		warn "Could not read $dir/$f\n";
	    }
	    else
	    {
		push(@list, $obj);
	    }
	}
    } else {
	warn "Could not open app-dir $dir: $!";
    }
    return @list;
}

sub find
{
    my($self, $app_id) = @_;

    my $dh;
    my $dir = $self->dir;

    my @list;
    
    #
    # We allow relaxed parsing of app definition files so that
    # we may put comments into them.
    #

    my $json = JSON::XS->new->relaxed(1);

    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = $json->decode(scalar read_file("$dir/$f"));
	    if (!$obj)
	    {
		warn "Could not read $dir/$f\n";
	    }
	    else
	    {
		if ($obj->{id} eq $app_id)
		{
		    return $obj;
		}
	    }
	}
    } else {
	warn "Could not open app-dir $dir: $!";
    }
    return undef;
}

1;
