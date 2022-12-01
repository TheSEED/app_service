use utf8;
package Bio::KBase::AppService::Schema::Result::ArchivedTask;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ArchivedTask

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

=head1 TABLE: C<ArchivedTask>

=cut

__PACKAGE__->table("ArchivedTask");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_nullable: 0

=head2 owner

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 parent_task

  data_type: 'integer'
  is_nullable: 1

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
  default_value: '1970-01-01 00:00:00'
  is_nullable: 0

=head2 start_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '1970-01-01 00:00:00'
  is_nullable: 1

=head2 finish_time

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: '1970-01-01 00:00:00'
  is_nullable: 1

=head2 monitor_url

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 output_path

  data_type: 'text'
  is_nullable: 1

=head2 output_file

  data_type: 'text'
  is_nullable: 1

=head2 params

  data_type: 'json'
  is_nullable: 1

=head2 app_spec

  data_type: 'json'
  is_nullable: 1

=head2 req_memory

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 req_cpu

  data_type: 'integer'
  is_nullable: 1

=head2 req_runtime

  data_type: 'integer'
  is_nullable: 1

=head2 req_policy_data

  data_type: 'text'
  is_nullable: 1

=head2 req_is_control_task

  data_type: 'tinyint'
  is_nullable: 1

=head2 search_terms

  data_type: 'text'
  is_nullable: 1

=head2 hidden

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 1

=head2 container_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 base_url

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 user_metadata

  data_type: 'text'
  is_nullable: 1

=head2 cluster_job_id

  data_type: 'integer'
  is_nullable: 1

=head2 cluster_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 job_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 job_status

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 maxrss

  data_type: 'float'
  is_nullable: 1

=head2 nodelist

  data_type: 'text'
  is_nullable: 1

=head2 exitcode

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 cancel_requested

  data_type: 'tinyint'
  default_value: 0
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_nullable => 0 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "parent_task",
  { data_type => "integer", is_nullable => 1 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "submit_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "1970-01-01 00:00:00",
    is_nullable => 0,
  },
  "start_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "1970-01-01 00:00:00",
    is_nullable => 1,
  },
  "finish_time",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => "1970-01-01 00:00:00",
    is_nullable => 1,
  },
  "monitor_url",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "output_path",
  { data_type => "text", is_nullable => 1 },
  "output_file",
  { data_type => "text", is_nullable => 1 },
  "params",
  { data_type => "json", is_nullable => 1 },
  "app_spec",
  { data_type => "json", is_nullable => 1 },
  "req_memory",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "req_cpu",
  { data_type => "integer", is_nullable => 1 },
  "req_runtime",
  { data_type => "integer", is_nullable => 1 },
  "req_policy_data",
  { data_type => "text", is_nullable => 1 },
  "req_is_control_task",
  { data_type => "tinyint", is_nullable => 1 },
  "search_terms",
  { data_type => "text", is_nullable => 1 },
  "hidden",
  { data_type => "tinyint", default_value => 0, is_nullable => 1 },
  "container_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "base_url",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "user_metadata",
  { data_type => "text", is_nullable => 1 },
  "cluster_job_id",
  { data_type => "integer", is_nullable => 1 },
  "cluster_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "job_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "job_status",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "maxrss",
  { data_type => "float", is_nullable => 1 },
  "nodelist",
  { data_type => "text", is_nullable => 1 },
  "exitcode",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "cancel_requested",
  { data_type => "tinyint", default_value => 0, is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=item * L</submit_time>

=back

=cut

__PACKAGE__->set_primary_key("id", "submit_time");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-03 15:42:34
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:eH6jTPNJNg5C8ccLoQQSYw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
