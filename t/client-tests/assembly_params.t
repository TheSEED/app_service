use Test::More;
use JSON::XS;

use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use_ok(Bio::KBase::AppService::AssemblyParams);

my $params_txt = <<'END';
{
  "paired_end_libs": [
    {
      "read1": "/fangfang/home/test/toy1.fq",
      "read2": "/fangfang/home/test/toy2.fq",
      "interleaved": false,
      "insert_size_mean": null
    },
    {
      "read1": "/fangfang/home/test/toy1-inter.fq",
      "interleaved": true,
      "insert_size_mean": null
    }
  ],
  "single_end_libs": [
    {
      "read": "/fangfang/home/test/toy1.fq"
    }
  ],
  "reference_assembly": "/fangfang/home/test/B93.contigs.fa",
  "recipe": "kiki",
  "output_path": "/fangfang/home/test/assm_5",
  "output_file": "toy"
}
END

my $params = decode_json($params_txt);

my $ap = new_ok('Bio::KBase::AppService::AssemblyParams', [$params]);

print Dumper($ap);

my $p = $ap->extract_params();

print Dumper($p);

done_testing;