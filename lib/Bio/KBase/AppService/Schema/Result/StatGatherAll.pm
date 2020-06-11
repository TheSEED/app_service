use utf8;
package Bio::KBase::AppService::Schema::Result::StatGatherAll;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::StatGatherAll - VIEW

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

=head1 TABLE: C<StatsGatherAll>

=cut

__PACKAGE__->table("StatsGatherAll");
__PACKAGE__->result_source_instance->view_definition("select month(`t`.`submit_time`) AS `month`,year(`t`.`submit_time`) AS `year`,`t`.`application_id` AS `application_id`,count(`t`.`id`) AS `job_count` from (`AppService`.`Task` `t` join `AppService`.`ServiceUser` `u` on((`t`.`owner` = `u`.`id`))) where ((`t`.`application_id` not in ('Date','Sleep')) and (`t`.`state_code` = 'C')) group by month(`t`.`submit_time`),year(`t`.`submit_time`),`t`.`application_id` order by year(`t`.`submit_time`),month(`t`.`submit_time`),`t`.`application_id`");

=head1 ACCESSORS

=head2 month

  data_type: 'integer'
  is_nullable: 1

=head2 year

  data_type: 'integer'
  extra: {unsigned => 1}
  is_nullable: 1

=head2 application_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 job_count

  data_type: 'bigint'
  default_value: 0
  is_nullable: 0

=cut

__PACKAGE__->add_columns(
  "month",
  { data_type => "integer", is_nullable => 1 },
  "year",
  { data_type => "integer", extra => { unsigned => 1 }, is_nullable => 1 },
  "application_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "job_count",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-04-09 23:30:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:4MHTj6jNjjnoxP6vC/IOcw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
