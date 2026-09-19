use v5.44;
use warnings;
use Test::More;
use File::Spec;
use FindBin qw($RealBin);
use JSON::PP ();

use lib "$RealBin/../lib";
use tubular::Adapter::ZSFM ();
use tubular::Config ();

# Optional REAL integration with the native zsfm executable.
#   TUBULAR_INTEGRATION=1            enable real invocation
#   TUBULAR_ZSFM_GGUF=/path.gguf     TimesFM GGUF to load (else config forecast.gguf)
# This test asserts plumbing only (process success, valid JSON, normalized
# response, horizon length). It never asserts a specific forecast number.
my $integration = $ENV{TUBULAR_INTEGRATION};
if (!defined $integration || $integration eq '') {
    plan skip_all => 'TUBULAR_INTEGRATION not set; real zsfm inference not exercised';
}

my $config = tubular::Config->new();
my $adapter = tubular::Adapter::ZSFM->new(
    timeout => $config->get('forecast', 'timeout'),
);
my $found = $adapter->find();
if (!defined $found) {
    plan skip_all => 'zsfm not found on this system; real inference not exercised';
}

my $gguf = $ENV{TUBULAR_ZSFM_GGUF};
$gguf = $config->get('forecast', 'gguf') if !defined $gguf || $gguf eq '';
if (!defined $gguf || $gguf eq '' || !-e $gguf || !-f $gguf) {
    plan skip_all => 'no TimesFM GGUF available (set TUBULAR_ZSFM_GGUF); real inference not exercised';
}

diag "zsfm:    $found";
diag "gguf:    $gguf";

my $start = $config->get('forecast', 'timeout') // 120;
my $res = $adapter->forecast(
    context => [ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ],
    horizon => 1,
    model   => 'timesfm',
    gguf    => $gguf,
);

ok($res->{ok}, 'real zsfm inference succeeded');
diag($res->{error}) if !$res->{ok};
diag($res->{stderr}) if defined $res->{stderr} && length $res->{stderr};

if ($res->{ok}) {
    is($res->{exit}, 0, 'process exit 0');
    is(ref $res->{result}, 'HASH', 'normalized result is a hashref');
    is(ref $res->{result}{point}, 'ARRAY', 'point is an arrayref');
    is(scalar @{ $res->{result}{point} }, 1, 'horizon length is 1');
    ok(defined $res->{runtime_ms} && $res->{runtime_ms} >= 0, 'runtime_ms reported');
    ok(
        !defined $res->{result}{quantiles}
            || (ref $res->{result}{quantiles} eq 'HASH'),
        'quantiles are absent or a hashref (never invented)',
    );
    ok(ref $res->{result}{raw_model} eq 'HASH', 'raw zsfm payload retained for debugging');
}

done_testing;