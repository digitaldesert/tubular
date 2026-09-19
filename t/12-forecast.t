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
use tubular::Forecast ();
use tubular::Sequence ();

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

sub forecast_for {
    return tubular::Forecast->forecast(@_);
}

subtest 'categorical markov conditioning on last value' => sub {
    my $r = forecast_for(values => [3, 2, 3, 1, 3], mode => 'categorical', horizon => 1);
    is($r->{ok}, 1, 'ok');
    is($r->{mode}, 'categorical', 'mode categorical');
    is($r->{context}{value}, 3, 'context is last value');
    is($r->{context}{position}, 5, 'context position 5');
    like($r->{context}{note}, qr/conditioning/, 'note recorded');
    my $s = $r->{steps}[0];
    is_deeply($s->{context}, 3, 'step reported context');
    is($s->{method}, 'markov1', 'method markov1');
    is($s->{label}, 'empirical', 'labelled empirical');
    is_deeply(
        $s->{estimates},
        [ { value => 1, p => 1/2 }, { value => 2, p => 1/2 } ],
        'empirical distribution from 3->2, 3->1',
    );
};

subtest 'estimates sorted by p desc then value asc' => sub {
    my $r = forecast_for(values => [5, 5, 7, 7, 9], mode => 'categorical', horizon => 1);
    my @e = @{ $r->{steps}[0]{estimates} };
    ok($e[0]{p} >= $e[1]{p}, 'p non-increasing');
    my @tied = ( $e[0]{value}, $e[1]{value} );
    is_deeply([sort { $a <=> $b } @tied], [sort @tied], 'ties deterministic');
};

subtest 'histogram fallback when context has no successor' => sub {
    my $r = forecast_for(values => [7], mode => 'categorical', horizon => 1);
    is($r->{ok}, 1, 'ok');
    is($r->{steps}[0]{method}, 'histogram', 'fell back to histogram');
    is($r->{steps}[0]{estimates}[0]{value}, 7, 'only observed value');
    is($r->{steps}[0]{estimates}[0]{p}, 1, 'p 1');
};

subtest 'chain extends deterministically over horizon' => sub {
    my $r = forecast_for(values => [1, 2, 1, 3, 1, 2, 3], mode => 'categorical', horizon => 3);
    is(scalar @{ $r->{steps} }, 3, 'three steps');
    is($r->{steps}[1]{context}, 1, 'step 2 context is step 1 top pick');
    is($r->{steps}[2]{context}, 2, 'step 3 context is step 2 top pick');
    is_deeply($r->{methods}, ['markov1'], 'one method');
};

subtest 'numeric mode uses histogram, no invented values' => sub {
    my $vals = [ map { $_ * 0.5 + 0.1 } 0 .. 19 ];
    my $r = forecast_for(values => $vals, mode => 'numeric', horizon => 1, top => 100);
    is($r->{mode}, 'numeric', 'mode numeric');
    my %observed;
    $observed{"$_"} = 1 for @$vals;
    for my $e (@{ $r->{steps}[0]{estimates} }) {
        ok($observed{"$e->{value}"}, "value $e->{value} is observed (not fabricated)");
    }
    is($r->{context}{value}, undef, 'no single-value context in numeric mode');
    like($r->{context}{note}, qr/numeric mode/, 'numeric note');
};

subtest 'auto picks categorical for few unique, numeric for many' => sub {
    my $small = forecast_for(values => [1, 2, 1, 2, 1], mode => 'auto');
    is($small->{mode}, 'categorical', 'auto -> categorical (<=12 unique)');

    my @many = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13);
    my $big = forecast_for(values => \@many, mode => 'auto');
    is($big->{mode}, 'numeric', 'auto -> numeric (>12 unique)');
};

subtest 'errors: empty, bad horizon, bad mode' => sub {
    my $e = forecast_for(values => [], mode => 'auto');
    is($e->{ok}, 0, 'empty rejected');
    like($e->{error}, qr/empty sequence/, 'message');

    $e = forecast_for(values => [1], mode => 'auto', horizon => 0);
    is($e->{ok}, 0, 'horizon 0 rejected');
    like($e->{error}, qr/horizon/, 'message');

    $e = forecast_for(values => [1], mode => 'bogus', horizon => 1);
    is($e->{ok}, 0, 'bad mode rejected');
    like($e->{error}, qr/unknown mode/, 'message');
};

subtest 'top truncates candidates' => sub {
    my $r = forecast_for(values => [1, 1, 2, 2, 3, 3, 4, 4, 5, 5], mode => 'numeric', horizon => 1, top => 2);
    is(scalar @{ $r->{steps}[0]{estimates} }, 2, 'two candidates');
};

subtest 'unique count reported' => sub {
    my $r = forecast_for(values => [1, 1, 2, 3, 3, 3], mode => 'categorical');
    is($r->{unique}, 3, 'unique=3');
};

subtest 'forecast CLI human output' => sub {
    my ($o, $e, $code) = run($binforecast, '--values', '3 2 3 1 3', '--horizon', '1', '--top', '1');
    is($code, 0, 'exit 0');
    like($o, qr/^values:\s+5   unique:\s+3$/m, 'summary line');
    like($o, qr/^mode:\s+categorical$/m, 'auto resolved mode shown');
    like($o, qr/^context \(conditioning on last observed value\):$/m, 'context section');
    like($o, qr/\Qvalue 3 at position 5\E/, 'context value+position');
    like($o, qr/^step 1  \(method: markov1, empirical\)$/m, 'step header');
    like($o, qr/\Q1            0.5000\E/, 'estimate row');
};

subtest 'forecast CLI --mode numeric and --top' => sub {
    my ($o, $e, $code) = run($binforecast, '--values', '1 2 1 3', '--mode', 'numeric', '--top', '1');
    is($code, 0, 'exit 0');
    like($o, qr/^mode:\s+numeric$/m, 'numeric mode');
    like($o, qr/no single-value conditioning/, 'numeric context note');
};

subtest 'forecast CLI reads CSV column' => sub {
    my $file = File::Spec->catfile($root, 't', 'fixtures', 'multi.csv');
    my ($o, $e, $code) = run($binforecast, $file, '--column', 'value');
    is($code, 0, 'exit 0');
    like($o, qr/^source:\s+\Q$file\E$/m, 'source shown');
};

subtest 'forecast CLI --json' => sub {
    my ($o, $e, $code) = run($binforecast, '--json', '--values', '1 2 1 3 2', '--horizon', '2', '--top', '1');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{mode}, 'categorical', 'mode in JSON');
    is(scalar @{ $j->{steps} }, 2, 'two steps');
    is($j->{steps}[0]{label}, 'empirical', 'label present');
    is($j->{context}{value}, 2, 'context in JSON');
    is_deeply($j->{methods}, ['markov1'], 'methods in JSON');
};

subtest 'forecast CLI errors' => sub {
    my (undef, $e, $code) = run($binforecast, File::Spec->catfile($root, 't', 'no-such-file.txt'));
    is($code, 1, 'missing file exit 1');

    (undef, $e, $code) = run($binforecast, '--mode', 'sideways');
    is($code, 2, 'bad mode exit 2');

    (undef, $e, $code) = run($binforecast);
    is($code, 2, 'no input exit 2');

    (undef, $e, $code) = run($binforecast, '--horizon', '0');
    is($code, 2, 'horizon 0 exit 2');

    my ($o, undef, $code2) = run($binforecast, '--help');
    is($code2, 0, 'help exit 0');
    like($o, qr/Usage:/, 'usage shown');
};

subtest 'dispatch through bin/tubular' => sub {
    my ($o, undef, $code) = run($tubular, 'forecast', '--values', '1 2 3 1 2 3 1');
    is($code, 0, 'tubular forecast works');
    like($o, qr/^mode:\s+categorical$/m, 'dispatch produces forecast');
};

done_testing;