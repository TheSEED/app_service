use Data::Dumper;
use Test::Exception;
use Test::More;
use strict;
use 5.010;
use JSON::XS;
use File::Temp;

my $json = JSON::XS->new->pretty(1);

use_ok('Bio::KBase::AppService::ReadSet');
use_ok('Bio::P3::Workspace::WorkspaceClientExt');

my $ws = new_ok('Bio::P3::Workspace::WorkspaceClientExt');

my $se1 = {
    read => '/ARWattam@patricbrc.org/Buchnera reads-PATRIC Workshop/SRR4240359.fastq',
};
my $se2 = {
    read => '/ARWattam@patricbrc.org/Buchnera reads-PATRIC Workshop/SRR4240359.fastq',
    platform => 'illumina',
};

my $pe1 = {
    read1 => '/PATRIC@patricbrc.org/PATRIC Workshop/Assembly/SRR3584989_1.fastq',
    read2 => '/PATRIC@patricbrc.org/PATRIC Workshop/Assembly/SRR3584989_2.fastq',
};
my $pe1_bad = {
    read1 => '/PATRIC@patricbrc.org/PATRIC Workshop/Assembly/SRR3584989_1.fastqx',
    read2 => '/olson@patricbrc.org/home/SRR2080393_1.fastq',
};
my $pe2 = {
    read1 => '/PATRIC@patricbrc.org/PATRIC Workshop/Assembly/SRR3584989_1.fastq',
    read2 => '/PATRIC@patricbrc.org/PATRIC Workshop/Assembly/SRR3584989_2.fastq',
    platform => 'illumina',
};

my $il1 = 		    {
    read1 => '/olson@patricbrc.org/home/SRR3584989.fastq.gz',
    interleaved => 1,
};

my $il2 = {
    read1 => '/olson@patricbrc.org/home/SRR3584989.fastq.gz',
    interleaved => 1,
    platform => 'illumina',
};

my $toyA = {
    read1 => '/olson@patricbrc.org/home/Binning-Webinar/toy1.fq',
    read2 => '/olson@patricbrc.org/home/Binning-Webinar/toy2.fq',
};

my $toyB = {
    read1 => '/olson@patricbrc.org/home/toy1.fq',
    read2 => '/olson@patricbrc.org/home/toy2.fq',
};

my $toyC = {
    read => '/olson@patricbrc.org/home/toy1.fq',
};


my %base = (output_file => "t1",
	    output_path => '/olson@patricbrc.org/home/test');

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, paired_end_libs => [$toyA, $toyB], single_end_libs => [$toyC]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');
my($ok, $errs) = $rs->validate($ws);
ok($ok);
my $tempdir = File::Temp->newdir();
$rs->localize_libraries("$tempdir");
print "Local: " . join(" ", $rs->paths() ), "\n";
$rs->stage_in($ws);
system("ls", "-l", "$tempdir");
undef $tempdir;

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, paired_end_libs => [$pe1]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');
my($ok, $errs) = $rs->validate($ws);
ok($ok);
$rs->localize_libraries('/tmp/test');

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, paired_end_libs => [$pe1_bad]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');
my($ok, $errs) = $rs->validate($ws);
ok(!$ok);
isa_ok($errs, 'ARRAY');
print join("\n", @$errs), "\n";

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, paired_end_libs => [$pe2]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, single_end_libs => [$se1]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, single_end_libs => [$se2]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');

my $rs = Bio::KBase::AppService::ReadSet->create_from_asssembly_params({ %base, paired_end_libs => [$pe1], single_end_libs => [$se2]});
isa_ok($rs, 'Bio::KBase::AppService::ReadSet');

$rs->localize_libraries("/tmp");
my @cmd = $rs->build_p3_assembly_arguments();
ok(@cmd > 0);
print "@cmd\n";

done_testing;
