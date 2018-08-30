use utf8;
package Bio::KBase::AppService::Schema::Result::JobGroup;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::JobGroup

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

=head1 TABLE: C<JobGroup>

=cut

__PACKAGE__->table("JobGroup");

=head1 ACCESSORS

=head2 parent_job

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 children_created

  data_type: 'integer'
  is_nullable: 1

=head2 children_completed

  data_type: 'integer'
  default_value: 0
  is_nullable: 1

=head2 parent_app

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 app_spec

  data_type: 'longtext'
  is_nullable: 1

=head2 app_params

  data_type: 'longtext'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "parent_job",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "children_created",
  { data_type => "integer", is_nullable => 1 },
  "children_completed",
  { data_type => "integer", default_value => 0, is_nullable => 1 },
  "parent_app",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "app_spec",
  { data_type => "longtext", is_nullable => 1 },
  "app_params",
  { data_type => "longtext", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</parent_job>

=back

=cut

__PACKAGE__->set_primary_key("parent_job");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:DEXDeQvFKNaQb74V8B2CBQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
