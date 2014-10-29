package Bio::KBase::AppService::Util;
use strict;
use File::Slurp;
use JSON::XS;

use base 'Class::Accessor';

__PACKAGE__->mk_accessors(qw(impl));

sub new
{
    my($class, $impl) = @_;

    my $self = {
	impl => $impl,
    };
    return bless $self, $class;
}

sub enumerate_apps
{
    my($self) = @_;

    my $dh;
    my $dir = $self->impl->{app_dir};

    my @list;
    
    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = sort { $a cmp $b } grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = decode_json(scalar read_file("$dir/$f"));
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

sub find_app
{
    my($self, $app_id) = @_;

    my $dh;
    my $dir = $self->impl->{app_dir};

    my @list;
    
    if (!$dir) {
	warn "No app directory specified\n";
    } elsif (opendir($dh, $dir)) {
	my @files = grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
	closedir($dh);
	for my $f (@files)
	{
	    my $obj = decode_json(scalar read_file("$dir/$f"));
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
