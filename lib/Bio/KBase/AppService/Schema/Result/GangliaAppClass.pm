use utf8;
package Bio::KBase::AppService::Schema::Result::GangliaAppClass;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::GangliaAppClass

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

=head1 TABLE: C<ganglia_app_class>

=cut

__PACKAGE__->table("ganglia_app_class");

=head1 ACCESSORS

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 100

=head2 class_name

  data_type: 'varchar'
  is_nullable: 1
  size: 50

=cut

__PACKAGE__->add_columns(
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 100 },
  "class_name",
  { data_type => "varchar", is_nullable => 1, size => 50 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-03-10 14:48:59
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:cU90EQ0KhCaLvIwNzQloPw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
