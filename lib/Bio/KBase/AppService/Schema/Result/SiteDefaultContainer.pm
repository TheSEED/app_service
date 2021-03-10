use utf8;
package Bio::KBase::AppService::Schema::Result::SiteDefaultContainer;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::SiteDefaultContainer

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

=head1 TABLE: C<SiteDefaultContainer>

=cut

__PACKAGE__->table("SiteDefaultContainer");

=head1 ACCESSORS

=head2 base_url

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 default_container_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "base_url",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "default_container_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</base_url>

=back

=cut

__PACKAGE__->set_primary_key("base_url");

=head1 RELATIONS

=head2 default_container

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Container>

=cut

__PACKAGE__->belongs_to(
  "default_container",
  "Bio::KBase::AppService::Schema::Result::Container",
  { id => "default_container_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-03-10 14:48:58
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:V6EqtIbT76SwZFjX+kEb4A


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
