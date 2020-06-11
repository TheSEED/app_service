use utf8;
package Bio::KBase::AppService::Schema::Result::TaskView;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::TaskView - VIEW

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

=head1 TABLE: C<TaskView>

=cut

__PACKAGE__->table("TaskView");
__PACKAGE__->result_source_instance->view_definition("select `t`.`id` AS `task_id`,`t`.`owner` AS `owner`,`t`.`parent_task` AS `parent_task`,`t`.`state_code` AS `state_code`,`t`.`application_id` AS `application_id`,`j`.`id` AS `id`,`j`.`job_id` AS `job_id` from (`AppService`.`Task` `t` left join `AppService`.`ClusterJob` `j` on((`t`.`id` = `j`.`task_id`)))");

=head1 ACCESSORS

=head2 task_id

  data_type: 'integer'
  default_value: 0
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

=head2 id

  data_type: 'integer'
  default_value: 0
  is_nullable: 1

=head2 job_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "task_id",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "owner",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "parent_task",
  { data_type => "integer", is_nullable => 1 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "id",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "job_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-17 16:42:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:dIbHp6ajXTGStbEgCDUcUA


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
