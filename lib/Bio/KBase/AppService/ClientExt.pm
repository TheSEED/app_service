#
# Extension of client module to add client-side logic.
#

package Bio::KBase::AppService::ClientExt;

use Data::Dumper;
use strict;
use base 'Bio::KBase::AppService::Client';

sub await_task_completion
{
    my($self, $task_ids, $query_frequency, $timeout) = @_;

    die "await_task_completion: invalid task IDs" if ref($task_ids) ne 'ARRAY';
    return [] if @$task_ids == 00;

    #  Handle case where a list of tasks is passed.
    if (ref($task_ids->[0]) eq 'HASH')
    {
	$task_ids = [ map { $_->{id} }  @$task_ids];
    }

    $query_frequency //= 10;

    my %final_states = map { $_ => 1 } qw(failed suspend completed user_skipped skipped passed deleted);

    my $end_time;
    if ($timeout)
    {
	my $end_time = time + $timeout;
    }

    my %order;
    for my $i (0..$#$task_ids)
    {
	$order{$task_ids->[$i]} = $i;
    }

    my %remaining = map { $_ => 1 } @$task_ids;

    my $result = [];
    print Dumper(\%remaining);
    while (%remaining && (!$end_time || (time < $end_time)))
    {
	my $qtasks = $self->query_tasks([keys %remaining]);
	while (my($qid, $qtask) = each %$qtasks)
	{
	    my $status = $qtask->{status};
	    print "Queried status = $status: " . Dumper($qtask);
	    if ($final_states{$status})
	    {
		#
		# This task is done; fill in result and remove from query list.
		#
		$result->[$order{$qid}] = $qtask;
		delete $remaining{$qid};
	    }
	}
	
	sleep($query_frequency);
    }
    return $result;
}

1;
