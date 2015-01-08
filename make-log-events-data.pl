use strict;

my $url = 'https://raw.githubusercontent.com/MG-RAST/AWE/master/lib/logger/event/event.go';

open(P, "-|", "curl", $url) or die $!;


print <<'END';

package Bio::KBase::AppService::AweEvents;
use strict;

our %events = (
END
	       
while (<P>)
{
    if (m,^\s+(\S+)\s+=\s+"([A-Z][A-Z])".*//(.*),)
    {
	print "$2 => ['$1', '$3'],\n";
    }
}
print ");\n";
print "1;\n";
