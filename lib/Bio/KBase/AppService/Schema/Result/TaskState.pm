use utf8;
package Bio::KBase::AppService::Schema::Result::TaskState;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::TaskState

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

=head1 TABLE: C<TaskState>

=cut

__PACKAGE__->table("TaskState");

=head1 ACCESSORS

=head2 code

  data_type: 'varchar'
  is_nullable: 0
  size: 10

=head2 description

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=cut

__PACKAGE__->add_columns(
  "code",
  { data_type => "varchar", is_nullable => 0, size => 10 },
  "description",
  { data_type => "varchar", is_nullable => 1, size => 255 },
);

=head1 PRIMARY KEY

=over 4

=item * L</code>

=back

=cut

__PACKAGE__->set_primary_key("code");

=head1 RELATIONS

=head2 tasks

Type: has_many

Related object: L<Bio::KBase::AppService::Schema::Result::Task>

=cut

__PACKAGE__->has_many(
  "tasks",
  "Bio::KBase::AppService::Schema::Result::Task",
  { "foreign.state_code" => "self.code" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:S1/vPBTLjVOjP625xflU0A


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
