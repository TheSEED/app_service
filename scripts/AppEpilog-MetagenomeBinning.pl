
#
# Metagenomic binning epilog script.
#
# This is invoked by the last genome annotation run on a bin from the
# metagenome.
#
# We are running with the task ID of the last genome annotation. We use this
# to look up in the GenomeAnnotation_JobDetails table to find the job ID
# of the parent, and then enumerate the child jobs.
#
# For each, save the annotated gto into a gto directory named as genome-id.gto.
#
# Create a package directory package-dir
# Then run the SEEDtk script "package_gto gto-dir all package-dir
# Now we an use the SEEDtk package/bin scripts to do the analysis required:
#   bins -d package-dir checkM <genome-id>
#   bins -d package-dir eval_scikit <genome_id>
#   bins -d package-dir quality_summary <genome_id>
#
#
# The epilog script uses the AppScript infrastructure to enable logging to
# the PATRIC monitoring service.
#

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::MetagenomeBinning;
use strict;
use Data::Dumper;
my $script = Bio::KBase::AppService::AppScript->new(\&process);
$script->donot_create_result_folder(1);

my $rc = $script->run(\@ARGV);

exit $rc;

sub process
{
    my($self, $app, $app_def, $raw_params, $params) = @_;

    die Dumper($self, $app, $app_def, $raw_params, $params);
}
