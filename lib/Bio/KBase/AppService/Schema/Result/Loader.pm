use utf8;
package Bio::KBase::AppService::Schema::Result::Loader;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Loader

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<DBIx::Class::InflateColumn::DateTime>

=back

=cut

__PACKAGE__->load_components("InflateColumn::DateTime");

=head1 TABLE: C<loader>

=cut

__PACKAGE__->table("loader");

=head1 ACCESSORS

=head2 cluster_job_id

  data_type: 'varchar'
  is_nullable: 0
  size: 36

=head2 owner

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 state_code

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 submit_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=head2 start_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=head2 finish_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  is_nullable: 1

=head2 output_path

  data_type: 'text'
  is_nullable: 1

=head2 output_file

  data_type: 'text'
  is_nullable: 1

=head2 exit_code

  data_type: 'varchar'
  is_nullable: 1
  size: 6

=head2 hostname

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 params

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "cluster_job_id",
  { data_type => "varchar", is_nullable => 0, size => 36 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "submit_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "start_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "finish_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    is_nullable => 1,
  },
  "output_path",
  { data_type => "text", is_nullable => 1 },
  "output_file",
  { data_type => "text", is_nullable => 1 },
  "exit_code",
  { data_type => "varchar", is_nullable => 1, size => 6 },
  "hostname",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "params",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</cluster_job_id>

=back

=cut

__PACKAGE__->set_primary_key("cluster_job_id");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-10-17 12:28:49
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gYerf/BwVNnVbKKkgBtzTA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
