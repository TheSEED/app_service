use utf8;
package Bio::KBase::AppService::Schema::Result::TaskExecution;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::TaskExecution

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

=head1 TABLE: C<TaskExecution>

=cut

__PACKAGE__->table("TaskExecution");

=head1 ACCESSORS

=head2 task_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 cluster_job_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 active

  data_type: 'tinyint'
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "task_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "cluster_job_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "active",
  { data_type => "tinyint", is_nullable => 0 },
);

=head1 RELATIONS

=head2 cluster_job

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::ClusterJob>

=cut

__PACKAGE__->belongs_to(
  "cluster_job",
  "Bio::KBase::AppService::Schema::Result::ClusterJob",
  { id => "cluster_job_id" },
  { is_deferrable => 1, on_delete => "RESTRICT", on_update => "RESTRICT" },
);

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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-05-15 13:09:04
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:PoXHPbJ0vEspnV0ElmO85A


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
