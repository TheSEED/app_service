
#
# Comprehensive Genome Analysis application
#
# This is a coordination/wrapper application that invokes a series of
# other applications to perform the actual work. 
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::ComprehensiveGenomeAnalysis;
use strict;
use Data::Dumper;

my $cga = Bio::KBase::AppService::ComprehensiveGenomeAnalysis->new();

my $script = Bio::KBase::AppService::AppScript->new(sub { $cga->run(@_); });

my $rc = $script->run(\@ARGV);

exit $rc;
