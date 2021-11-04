use utf8;
package Bio::KBase::AppService::Schema::Result::DataContainer;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::DataContainer

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

=head1 TABLE: C<DataContainer>

=cut

__PACKAGE__->table("DataContainer");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 name

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "name",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 site_default_data_containers

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::SiteDefaultDataContainer>

=cut

__PACKAGE__->has_many(
  "site_default_data_containers",
  "Bio::KBase::AppService::Schema::Result::SiteDefaultDataContainer",
  { "foreign.default_data_container_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-03 15:42:34
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:XzfoJ/k7hKYcZhfSs+f4sQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
