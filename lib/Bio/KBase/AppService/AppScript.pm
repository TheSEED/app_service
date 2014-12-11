package Bio::KBase::AppService::AppScript;

use strict;
use JSON::XS;
use File::Slurp;
use IO::File;
use Capture::Tiny 'capture';

use base 'Class::Accessor';

use Data::Dumper;

__PACKAGE__->mk_accessors(qw(callback));

sub new
{
    my($class, $callback) = @_;

    my $self = {
	callback => $callback,
    };
    return bless $self, $class;
}

sub run
{
    my($self, $args) = @_;
    
    @$args == 2 or @$args == 4 or die "Usage: $0 app-definition.json param-values.json [stdout-file stderr-file]\n";
    
    my $json = JSON::XS->new->pretty(1);

    my $app_def_file = shift @$args;
    my $params_file = shift @$args;

    my $stdout_file = shift @$args;
    my $stderr_file = shift @$args;

    my $app_def = $json->decode(scalar read_file($app_def_file));
    my $params =  $json->decode(scalar read_file($params_file));

    #
    # Preprocess parameters to create hash of named parameters, looking for
    # missing required values and filling in defaults.
    #

    my %proc_param;

    my @errors;
    for my $param (@{$app_def->{parameters}})
    {
	my $id = $param->{id};
	if (exists($params->{$id}))
	{
	    my $value = $params->{$param->{id}};
	    #
	    # Maybe validate.
	    #

	    $proc_param{$id} = $value;
	}
	else
	{
	    if ($param->{required})
	    {
		push(@errors, "Required parameter $param->{label} ($id) missing");
		next;
	    }
	    if ($param->{default})
	    {
		$proc_param{$id} = $param->{default};
	    }
	}
    }
    if (@errors)
    {
	die "Errors found in parameter processing:\n    " . join("\n    ", @errors), "\n";
    }
	 
    if ($stdout_file)
    {
	my $stdout_fh = IO::File->new($stdout_file, "w+");
	my $stderr_fh = IO::File->new($stderr_file, "w+");
	
	capture(sub { $self->callback->($app_def, $params, \%proc_param) } , stdout => $stdout_fh, stderr => $stderr_fh);
    }
    else
    {
	$self->callback->($app_def, $params, \%proc_param);
    }
}

1;
