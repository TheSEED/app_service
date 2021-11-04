use utf8;
package Bio::KBase::AppService::Schema::Result::TaskParam;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::TaskParam

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

=head1 TABLE: C<TaskParams>

=cut

__PACKAGE__->table("TaskParams");

=head1 ACCESSORS

=head2 task_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 app_spec

  data_type: 'json'
  is_nullable: 1

=head2 params

  data_type: 'json'
  is_nullable: 1

=head2 preflight

  data_type: 'json'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "task_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "app_spec",
  { data_type => "json", is_nullable => 1 },
  "params",
  { data_type => "json", is_nullable => 1 },
  "preflight",
  { data_type => "json", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</task_id>

=back

=cut

__PACKAGE__->set_primary_key("task_id");

=head1 RELATIONS

=head2 task

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->belongs_to(
  "task",
  "Bio::KBase::AppService::Schema::Result::Task",
  { id => "task_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-03 15:42:34
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:uOq1P3PvOfO34yHtgciwfw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
