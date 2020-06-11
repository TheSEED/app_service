use utf8;
package Bio::KBase::AppService::Schema::Result::StatsGatherCollab;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::StatsGatherCollab - VIEW

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

=head1 TABLE: C<StatsGatherCollab>

=cut

__PACKAGE__->table("StatsGatherCollab");
__PACKAGE__->result_source_instance->view_definition("select month(`t`.`submit_time`) AS `month`,year(`t`.`submit_time`) AS `year`,concat(`t`.`application_id`,'-collab') AS `application_id`,count(`t`.`id`) AS `job_count` from (`AppService`.`Task` `t` join `AppService`.`ServiceUser` `u` on((`t`.`owner` = `u`.`id`))) where ((`t`.`application_id` in ('GenomeAssembly','GenomeAssembly2','GenomeAnnotation')) and (`u`.`is_collaborator` = 1) and (`u`.`is_staff` = 0) and (`t`.`state_code` = 'C')) group by month(`t`.`submit_time`),year(`t`.`submit_time`),`t`.`application_id` order by year(`t`.`submit_time`),month(`t`.`submit_time`),`t`.`application_id`");

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
  size: 262

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
  { data_type => "varchar", is_nullable => 1, size => 262 },
  "job_count",
  { data_type => "bigint", default_value => 0, is_nullable => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2020-04-09 23:30:46
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:QTVNmHCwqo6zTv1Or4vszg


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
