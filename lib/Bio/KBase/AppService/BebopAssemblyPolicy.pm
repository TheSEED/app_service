package Bio::KBase::AppService::BebopAssemblyPolicy;

use 5.010;
use strict;
use P3AuthToken;
use base 'Class::Accessor';
use Data::Dumper;
use Try::Tiny;
use DateTime;
use JSON::XS;

=head1 NAME 

Bio::KBase::AppService::BebopAssemblyPolicy - queue policy for running assembly apps on Bebop

=head1 SYNOPSIS

    $policy = Bio::KBase::AppService::BebopAssemblyPolicy->new($cluster_obj);
    $policy->start_tasks($scheduler);

=head1 DESCRIPTION

This policy object attempts to pluck assembly jobs from the queue and schedule
sets of them onto the Bebop cluster.

=head2 METHODS

=over 4

=item B<new>

=over 4

=item Arguments: L<$cluster_obj|Bio::KBase::AppService::SlurmCluster>

=item Return Value: L<$policy_obj|Bio::KBase::AppService::BebopAssemblyPolicy>

=back

Create the policy object for submission to the given cluster.

=cut

sub new
{
    my($class, $cluster) = @_;

    my $self = {
	cluster => $cluster,
    };
    return bless $self, $class;
}

=item B<start_tasks>
    
=over 4

=item Arguments: L<$scheduler|Bio::KBase::AppService::Scheduler>

=item Return Value: none

=back

Attempt to pluck sets of assembly jobs to submit to the Bebop cluster.




=back 

=cut

1;
