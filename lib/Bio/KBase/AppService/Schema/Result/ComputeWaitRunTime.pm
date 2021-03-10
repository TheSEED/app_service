use utf8;
package Bio::KBase::AppService::Schema::Result::ComputeWaitRunTime;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::ComputeWaitRunTime - VIEW

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
__PACKAGE__->table_class("DBIx::Class::ResultSource::View");

=head1 TABLE: C<compute_wait_run_time>

=cut

__PACKAGE__->table("compute_wait_run_time");
__PACKAGE__->result_source_instance->view_definition("select `AppService`.`Task`.`id` AS `id`,`AppService`.`Task`.`application_id` AS `application_id`,`AppService`.`Task`.`state_code` AS `state_code`,timediff(`AppService`.`Task`.`start_time`,`AppService`.`Task`.`submit_time`) AS `wait`,timediff(`AppService`.`Task`.`finish_time`,`AppService`.`Task`.`start_time`) AS `run` from `AppService`.`Task` where (`AppService`.`Task`.`state_code` = 'C')");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  default_value: 0
  is_nullable: 0

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 state_code

  data_type: 'varchar'
  is_nullable: 1
  size: 10

=head2 wait

  data_type: 'time'
  is_nullable: 1

=head2 run

  data_type: 'time'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", default_value => 0, is_nullable => 0 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "state_code",
  { data_type => "varchar", is_nullable => 1, size => 10 },
  "wait",
  { data_type => "time", is_nullable => 1 },
  "run",
  { data_type => "time", is_nullable => 1 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-03-10 14:48:59
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:9mzdlrXOUyGWNEyNBsLdnQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
