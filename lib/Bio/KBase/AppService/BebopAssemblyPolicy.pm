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

=cut
