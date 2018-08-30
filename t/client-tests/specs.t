use Data::Dumper;
use Test::More;
use strict;
use 5.010;

use_ok('Bio::KBase::AppService::AppSpecs');

my $dir = shift;

my $specs = new_ok('Bio::KBase::AppService::AppSpecs', [$dir]);

my $sleep = $specs->find("Sleep");

is(ref($sleep), 'HASH');
is($sleep->{id}, 'Sleep');

my @list = $specs->enumerate();
print Dumper(\@list);
cmp_ok(scalar @list, '>', 0);

done_testing;
