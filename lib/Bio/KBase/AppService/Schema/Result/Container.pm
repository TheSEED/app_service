use utf8;
package Bio::KBase::AppService::Schema::Result::Container;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Container

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

=head1 TABLE: C<Container>

=cut

__PACKAGE__->table("Container");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 filename

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 creation_date

  data_type: 'timestamp'
  datetime_undef_if_invalid: 1
  default_value: current_timestamp
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "filename",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "creation_date",
  {
    data_type => "timestamp",
    datetime_undef_if_invalid => 1,
    default_value => \"current_timestamp",
    is_nullable => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 clusters

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Cluster>

=cut

__PACKAGE__->has_many(
  "clusters",
  "Bio::KBase::AppService::Schema::Result::Cluster",
  { "foreign.default_container_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);

=head2 tasks

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->has_many(
  "tasks",
  "Bio::KBase::AppService::Schema::Result::Task",
  { "foreign.container_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-04-10 12:21:17
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:dtDoHwmNNvAS3iazs9HlUg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
