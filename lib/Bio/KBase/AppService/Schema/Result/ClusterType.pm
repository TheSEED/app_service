use utf8;
package Bio::KBase::AppService::Schema::Result::ClusterType;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ClusterType

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

=head1 TABLE: C<ClusterType>

=cut

__PACKAGE__->table("ClusterType");

=head1 ACCESSORS

=head2 type

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=cut

__PACKAGE__->add_columns(
  "type",
  { data_type => "varchar", is_nullable => 0, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</type>

=back

=cut

__PACKAGE__->set_primary_key("type");

=head1 RELATIONS

=head2 clusters

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Cluster>

=cut

__PACKAGE__->has_many(
  "clusters",
  "Bio::KBase::AppService::Schema::Result::Cluster",
  { "foreign.type" => "self.type" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:V1nei50Tr8D1pgQIKjgvig


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
