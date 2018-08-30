use utf8;
package Bio::KBase::AppService::Schema::Result::Application;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::Application

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

=head1 TABLE: C<Application>

=cut

__PACKAGE__->table("Application");

=head1 ACCESSORS

=head2 id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 script

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 default_memory

  data_type: 'integer'
  is_nullable: 1

=head2 default_cpu

  data_type: 'integer'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "script",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "default_memory",
  { data_type => "integer", is_nullable => 1 },
  "default_cpu",
  { data_type => "integer", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 tasks

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->has_many(
  "tasks",
  "Bio::KBase::AppService::Schema::Result::Task",
  { "foreign.application_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:z/UDatlKrsizoqiqLc2uBg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
