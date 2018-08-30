use utf8;
package Bio::KBase::AppService::Schema::Result::GenomeAnnotationJobDetail;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Bio::KBase::AppService::Schema::Result::GenomeAnnotationJobDetail

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

=head1 TABLE: C<GenomeAnnotation_JobDetails>

=cut

__PACKAGE__->table("GenomeAnnotation_JobDetails");

=head1 ACCESSORS

=head2 job_id

  data_type: 'varchar'
  is_nullable: 0
  size: 255

=head2 parent_job

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 genome_id

  data_type: 'varchar'
  is_nullable: 1
  size: 255

=head2 genome_name

  data_type: 'text'
  is_nullable: 1

=head2 gto_path

  data_type: 'text'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "job_id",
  { data_type => "varchar", is_nullable => 0, size => 255 },
  "parent_job",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "genome_id",
  { data_type => "varchar", is_nullable => 1, size => 255 },
  "genome_name",
  { data_type => "text", is_nullable => 1 },
  "gto_path",
  { data_type => "text", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</job_id>

=back

=cut

__PACKAGE__->set_primary_key("job_id");


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2018-08-29 13:04:51
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Vb0MGNnrqKioubqsN8/jew


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
