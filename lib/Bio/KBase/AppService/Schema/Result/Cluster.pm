use utf8;
package Bio::KBase::AppService::Schema::Result::Cluster;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Cluster

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

=head1 TABLE: C<Cluster>

=cut

__PACKAGE__->table("Cluster");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 type

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=head2 name

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 remote_host

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 account

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 remote_user

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 remote_keyfile

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 scheduler_install_path

  data_type: 'text'
  is_nullable: 1

=head2 temp_path

  data_type: 'text'
  is_nullable: 1

=head2 p3_runtime_path

  data_type: 'text'
  is_nullable: 1

=head2 p3_deployment_path

  data_type: 'text'
  is_nullable: 1

=head2 max_allowed_jobs

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "type",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "name",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "remote_host",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "account",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "remote_user",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "remote_keyfile",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "scheduler_install_path",
  { data_type => "text", is_nullable => 1 },
  "temp_path",
  { data_type => "text", is_nullable => 1 },
  "p3_runtime_path",
  { data_type => "text", is_nullable => 1 },
  "p3_deployment_path",
  { data_type => "text", is_nullable => 1 },
  "max_allowed_jobs",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 cluster_jobs

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::ClusterJob>

=cut

__PACKAGE__->has_many(
  "cluster_jobs",
  "Bio::KBase::AppService::Schema::Result::ClusterJob",
  { "foreign.cluster_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 type

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::ClusterType>

=cut

__PACKAGE__->belongs_to(
  "type",
  "Bio::KBase::AppService::Schema::Result::ClusterType",
  { type => "type" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2019-01-24 14:40:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:gdMRa1oCCwdRZo5YV8T8Qg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
