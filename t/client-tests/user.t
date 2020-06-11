use Data::Dumper;
use Test::Exception;
use Test::More;
use strict;
use 5.010;

use_ok('P3AuthToken');
use_ok('Bio::KBase::AppService::AppSpecs');
use_ok('Bio::KBase::AppService::Scheduler');
use_ok('Bio::KBase::AppService::SlurmCluster');

my $dir = shift;

my $token = new_ok('P3AuthToken');

my $specs = new_ok('Bio::KBase::AppService::AppSpecs', [$dir]);

my $sched = new_ok('Bio::KBase::AppService::Scheduler', [specs => $specs]);

my $cluster = new_ok('Bio::KBase::AppService::SlurmCluster', ['TSlurm', schema => $sched->schema]);

$sched->default_cluster($cluster);

my $u1 = 'olson@patricbrc.org';

my $u = $sched->find_user($u1, $token);
print "Found user " . $u->id . " " . $u->project_id . "\n";

done_testing;
