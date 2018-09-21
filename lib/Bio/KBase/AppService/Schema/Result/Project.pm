use utf8;
package Bio::KBase::AppService::Schema::Result::Project;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Project

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

=head1 TABLE: C<Project>

=cut

__PACKAGE__->table("Project");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 userid_domain

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "userid_domain",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 service_users

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::ServiceUser>

=cut

__PACKAGE__->has_many(
  "service_users",
  "Bio::KBase::AppService::Schema::Result::ServiceUser",
  { "foreign.project_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-09-10 16:59:02
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:R9j0kD4bPlUjdTmqZIEnvw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
