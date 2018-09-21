use utf8;
package Bio::KBase::AppService::Schema::Result::ClusterJob;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ClusterJob

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

=head1 TABLE: C<ClusterJob>

=cut

__PACKAGE__->table("ClusterJob");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 cluster_id

  data_type: 'varchar'
  is_foreign_key: 1
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

  data_type: 'integer'
  extra: {unsigned => 1}
  is_nullable: 1

=head2 nodelist

  data_type: 'text'
  is_nullable: 1

=head2 exitcode

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "cluster_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "job_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "job_status",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "maxrss",
  { data_type => "integer", extra => { unsigned => 1 }, is_nullable => 1 },
  "nodelist",
  { data_type => "text", is_nullable => 1 },
  "exitcode",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 cluster

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Cluster>

=cut

__PACKAGE__->belongs_to(
  "cluster",
  "Bio::KBase::AppService::Schema::Result::Cluster",
  { id => "cluster_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 task_executions

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::TaskExecution>

=cut

__PACKAGE__->has_many(
  "task_executions",
  "Bio::KBase::AppService::Schema::Result::TaskExecution",
  { "foreign.cluster_job_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-21 11:23:56
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:xpg2G3eZqSTTXEGRluMvdw

__PACKAGE__->many_to_many(tasks => 'task_executions', 'task');

# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
