use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use FindBin qw($RealBin);
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

use lib "$RealBin/../lib";
use tubular::Forecast;

my $root = dirname($RealBin);
my $binforecast = File::Spec->catfile($root, 'bin', 'forecast');
my $tubular = File::Spec->catfile($root, 'bin', 'tubular');

sub run (@args) {
    my $err_rd = gensym();
    my $pid = open3(my $in, my $out_rd, $err_rd, $^X, @args);
    close $in;
    my $out = '';
    my $err = '';
    local $/;
    $out = <$out_rd> // '';
    $err = <$err_rd> // '';
    waitpid $pid, 0;
    my $code = $? >> 8;
    return ($out, $err, $code);
}

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};

sub approx {
    my ($got, $exp, $tol) = @_;
    $tol //= 1e-6;
    return abs($got - $exp) <= $tol;
}

subtest 'weights derived from backtest inverse-MAE' => sub {
    my $r = tubular::Forecast->ensemble(
        values   => [1, 2, 1, 2, 1, 2],
        horizon  => 1,
        top      => 3,
        window   => 0,
        min_train => 2,
    );
    is($r->{ok}, 1, 'ok');
    is($r->{mode}, 'ensemble', 'mode ensemble');
    is($r->{n}, 6, 'n');
    like($r->{weight_source}, qr/inverse-MAE/, 'formula documented');

    my $w = $r->{weights};
    is(@{ [ sort keys %$w ] }, 4, 'four weighted members');
    my $sum = 0;
    $sum += $_ for values %$w;
    ok(approx($sum, 1, 1e-6), "weights sum to 1 (got $sum)");

    # Hand-computed from the rolling MAEs below (min_train 2, window 0):
    #   last  mae 1.0        -> w 0.5        /2.80496
    #   mean  mae 0.5666666.. -> w 0.638298
    #   markov1 mae 0        -> w 1.0
    #   histogram mae 0.5    -> w 0.6666667
    ok(approx($w->{last}, 0.5      / 2.804964, 1e-4), 'last weight');
    ok(approx($w->{mean}, 0.638298 / 2.804964, 1e-4), 'mean weight');
    ok(approx($w->{markov1}, 1.0   / 2.804964, 1e-4), 'markov1 weight');
    ok(approx($w->{histogram}, 0.6666667 / 2.804964, 1e-4), 'histogram weight');
    is(undef, $r->{fallback}, 'no fallback triggered');

    # Step 1 mixture on context 2:
    #   last {2:1}; mean {1.5:1}; markov1 {1:1}; histogram {1:1/2,2:1/2}
    my $e = $r->{steps}[0]{estimates};
    ok(approx($e->[0]{value}, 1, 1e-6), 'top candidate 1');
    ok(approx($e->[0]{p}, 0.4753245, 1e-4), 'mixture probability for 1');
    ok(approx($e->[2]{value}, 1.5, 1e-6), 'mean value appears as 3rd candidate');
    is($r->{steps}[0]{method}, 'ensemble', 'step method label');
    is($r->{steps}[0]{label}, 'empirical', 'estimates labelled empirical');
    is_deeply($r->{methods}, ['ensemble'], 'one reported method');
};

subtest 'single value cannot be ensembled' => sub {
    my $r = tubular::Forecast->ensemble(values => [5], horizon => 1, top => 2);
    is($r->{ok}, 0, 'single value rejected');
    like($r->{error}, qr/at least 2 values/, 'backtest requirement reported');
};

subtest 'ensemble validation errors' => sub {
    my $r = tubular::Forecast->ensemble(values => []);
    is($r->{ok}, 0, 'empty rejected');
    like($r->{error}, qr/empty sequence/, 'message');

    $r = tubular::Forecast->ensemble(values => [1, 2, 3], horizon => 0);
    is($r->{ok}, 0, 'horizon 0 rejected');
};

subtest 'ensemble CLI human output' => sub {
    my ($o, $e, $code) = run($binforecast, '--values', '1 2 1 2 1 2 3', '--ensemble', '--horizon', '1', '--window', '0', '--min-train', '2');
    is($code, 0, 'exit 0');
    like($o, qr/^mode:\s+ensemble$/m, 'ensemble mode');
    like($o, qr/^step 1  \(method: ensemble, empirical\)$/m, 'step header');
    like($o, qr/^weighting:\s+backtest inverse-MAE/m, 'weighting line');
    like($o, qr/^  markov1\s+/m, 'weight row shown');
};

subtest 'ensemble defaults clamp gracefully on small input' => sub {
    my ($o, $e, $code) = run($binforecast, '--values', '4 4', '--ensemble');
    is($code, 0, 'small input still works with default 10 min-train');
    like($o, qr/^mode:\s+ensemble$/m, 'ensemble mode');
    like($o, qr/^  last\s+/m, 'weights shown for clamped min-train');
};

subtest 'ensemble option conflicts' => sub {
    my (undef, $e, $code) = run($binforecast, '--values', '1 2 3', '--ensemble', '--mode', 'numeric');
    is($code, 2, 'ensemble with mode rejected');

    (undef, $e, $code) = run($binforecast, '--values', '1 2 3', '--window', '5');
    is($code, 2, '--window without --ensemble rejected');

    (undef, $e, $code) = run($binforecast, '--values', '1 2 3', '--ensemble', '--min-train', '0');
    is($code, 2, 'min-train 0 rejected');
};

subtest 'ensemble CLI --json' => sub {
    my ($o, $e, $code) = run($binforecast, '--json', '--values', '1 2 1 2 1 2', '--ensemble', '--horizon', '1', '--window', '0', '--min-train', '2', '--top', '2');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{mode}, 'ensemble', 'mode in JSON');
    ok(exists $j->{weights}{last}, 'weights in JSON');
    is($j->{steps}[0]{method}, 'ensemble', 'step method in JSON');
    is($j->{steps}[0]{label}, 'empirical', 'label in JSON');
    is_deeply($j->{methods}, ['ensemble'], 'methods in JSON');
    ok(exists $j->{weight_source}, 'weight_source in JSON');
};

subtest 'dispatch through bin/tubular' => sub {
    my ($o, undef, $code) = run($tubular, 'forecast', '--values', '1 2 1 2 3 3', '--ensemble', '--min-train', '2');
    is($code, 0, 'tubular forecast --ensemble works');
    like($o, qr/^mode:\s+ensemble$/m, 'ensemble mode via dispatch');
    like($o, qr/inverse-MAE/, 'weighting explained');
};

done_testing;