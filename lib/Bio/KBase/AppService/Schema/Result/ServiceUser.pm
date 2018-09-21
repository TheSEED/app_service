use utf8;
package Bio::KBase::AppService::Schema::Result::ServiceUser;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ServiceUser

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

=head1 TABLE: C<ServiceUser>

=cut

__PACKAGE__->table("ServiceUser");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 project_id

  data_type: 'varchar'
  is_foreign_key: 1
  is_nullable: 1
  size: 255

=head2 first_name

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 last_name

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 email

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 affiliation

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "project_id",
  { data_type => "varchar", is_foreign_key => 1, is_nullable => 1, size => 255 },
  "first_name",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "last_name",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "email",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "affiliation",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 project

Type: belongs_to

Related object: L<Bio::KBase::AppService::Schema::Result::Project>

=cut

__PACKAGE__->belongs_to(
  "project",
  "Bio::KBase::AppService::Schema::Result::Project",
  { id => "project_id" },
  {
    is_deferrable => 1,
    join_type     => "LEFT",
    on_delete     => "RESTRICT",
    on_update     => "RESTRICT",
  },
);

=head2 tasks

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->has_many(
  "tasks",
  "Bio::KBase::AppService::Schema::Result::Task",
  { "foreign.owner" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-12 15:51:03
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:0l2uhC15unJrCeoYnnnCWQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
