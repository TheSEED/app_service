use utf8;
package Bio::KBase::AppService::Schema::Result::MergedTaskStatus;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::MergedTaskStatus - VIEW

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
__PACKAGE__->table_class("DBIx::Class::ResultSource::View");

=head1 TABLE: C<MergedTaskStatus>

=cut

__PACKAGE__->table("MergedTaskStatus");
__PACKAGE__->result_source_instance->view_definition("select `t`.`id` AS `id`,`t`.`owner` AS `owner`,`t`.`state_code` AS `state_code`,`cj`.`job_status` AS `job_status` from ((`AppService`.`Task` `t` left join `AppService`.`TaskExecution` `te` on((`t`.`id` = `te`.`task_id`))) left join `AppService`.`ClusterJob` `cj` on((`cj`.`id` = `te`.`cluster_job_id`))) where ((`te`.`active` = 1) or isnull(`te`.`active`))");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 owner

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 state_code

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 job_status

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "job_status",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-04-09 23:30:45
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:73pdgt58Go/DfquGBAKbfw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
