use Data::Dumper;
use Test::Exception;
use Test::More;
use strict;
use 5.010;

use_ok('Bio::KBase::AppService::AppSpecs');
use_ok('Bio::KBase::AppService::Scheduler');

my $dir = shift;

my $specs = new_ok('Bio::KBase::AppService::AppSpecs', [$dir]);

my $sched = new_ok('Bio::KBase::AppService::Scheduler', [specs => $specs]);

my $code = $sched->schema->resultset('TaskState')->find({description => 'Submitted'});
ok($code);
say $code->id;
#
# Test app lookup/creation
#

my $res = $sched->find_app("Sleep");
isa_ok($res, 'Bio::KBase::AppService::Schema::Result::Application');
say "res=" . $res->id . " " . ref($res);;

dies_ok { $sched->find_app("Sleepx") };

my $task = $sched->start_app("Sleep", { sleep_time => 10 }, {});

done_testing;
