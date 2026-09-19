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
use tubular::Backtest;

my $root = dirname($RealBin);
my $binbacktest = File::Spec->catfile($root, 'bin', 'backtest');
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

sub bt {
    return tubular::Backtest->evaluate(@_);
}

sub approx {
    my ($got, $exp, $tol) = @_;
    $tol //= 1e-9;
    return abs($got - $exp) <= $tol;
}

subtest 'no look-ahead: hand-computed rolling predictions' => sub {
    # Sequence 5 5 9 5 9 5 9. Each prediction must use only the trailing
    # slice up to the position being scored; the truth value (the next
    # element) is never part of training.
    my $r = bt(
        values        => [5, 5, 9, 5, 9, 5, 9],
        window        => 0,    # entire history, still no future
        min_train     => 3,
        top           => 1,
        methods       => ['last', 'mean', 'markov1', 'histogram'],
    );
    is($r->{ok}, 1, 'ok');
    is($r->{positions}, 4, 'four positions scored');

    my %by;
    $by{ $_->{method} } = $_ for @{ $r->{methods} };

    # last: predicts 9,5,9,5 against 5,9,5,9 -> err 4 each.
    ok(approx($by{last}{mae}, 4),        'last mae 4');
    ok(approx($by{last}{rmse}, 4),        'last rmse 4');

    # markov1: pos 3 train [5,5,9,5] ctx 5 -> {5,9} tie, pick 5 -> err 4;
    # pos 4 ctx 9 -> next 5 -> err 0; pos 5 ctx 5 -> next 9 -> err 0.
    ok(approx($by{markov1}{mae}, 4/3),    'markov1 mae 4/3');
    ok(approx($by{markov1}{rmse}, sqrt(16/3)), 'markov1 rmse sqrt(16/3)');
    is($by{markov1}{positions}, 3, 'markov1 scored 3 positions (no context at pos 2)');
    is($by{markov1}{hits}, 2, 'markov1 hit twice');

    # The two hits prove the scorer never folds the truth into training at
    # the same position (positions 4 and 5 were correct single-step picks).
};

subtest 'window limits training slice' => sub {
    my $r = bt(
        values    => [1, 2, 3, 4, 1, 2, 3],
        window    => 2,
        min_train => 2,
        top       => 1,
        methods   => ['last'],
    );
    is($r->{ok}, 1, 'ok');
    is($r->{positions}, 5, 'five positions');

    # last predicts 3? at pos -> train slice always ends at current value.
    # With window 2 the slice is <= 2 elements, so we simply confirm no
    # index panic and consistent per-method accounting.
    my $last = $r->{methods}[0];
    is($last->{positions}, 5, 'last scored everywhere');
    ok(defined $last->{mae}, 'mae defined');
};

subtest 'max_positions caps evaluation count' => sub {
    my $vals = [ 1 .. 30 ];
    my $r = bt(values => $vals, min_train => 3, max_positions => 5, methods => ['last']);
    is($r->{positions}, 5, 'capped at 5 positions');

    $r = bt(values => $vals, min_train => 3, max_positions => 1000, methods => ['last']);
    is($r->{positions}, 27, 'uncapped positions');
};

subtest 'random baseline reproducible with seed' => sub {
    my $base = [];
    for my $seed (qw(11 99)) {
        my $r1 = bt(values => [3, 1, 4, 1, 5, 9, 2, 6], min_train => 3, methods => ['random'], seed => $seed);
        my $r2 = bt(values => [3, 1, 4, 1, 5, 9, 2, 6], min_train => 3, methods => ['random'], seed => $seed);
        is($r1->{methods}[0]{mae}, $r2->{methods}[0]{mae}, "seed $seed: same mae");
        is($r1->{methods}[0]{rmse}, $r2->{methods}[0]{rmse}, "seed $seed: same rmse");
        ok(defined $r1->{seed}, "seed recorded");
    }
};

subtest 'validation errors' => sub {
    my $r = bt(values => [7], min_train => 1, methods => ['last']);
    is($r->{ok}, 0, 'single value rejected');
    like($r->{error}, qr/at least 2 values/, 'message');

    $r = bt(values => [1, 2, 3], min_train => 3, methods => ['last']);
    is($r->{ok}, 0, 'min_train >= n rejected');
    like($r->{error}, qr/min_train/, 'message');

    $r = bt(values => [1, 2, 3], min_train => 1, window => -1, methods => ['last']);
    is($r->{ok}, 0, 'negative window rejected');
    like($r->{error}, qr/window/, 'message');
};

subtest 'backtest CLI human output' => sub {
    my ($o, $e, $code) = run($binbacktest, '--values', '5 5 9 5 9 5 9', '--min-train', '3', '--window', '0');
    is($code, 0, 'exit 0');
    like($o, qr{^source:\s+values$}m, 'source');
    like($o, qr{^values:\s+7   positions scored:\s+4$}m, 'summary');
    like($o, qr{^method\s+mae}m, 'table header');
    like($o, qr{^markov1\s+1\.3333}m, 'markov1 mae row');
    like($o, qr{^last\s+4\.0000}m, 'last row');
    like($o, qr{hit_rate}m, 'hit rate column');
};

subtest 'backtest CLI --methods and --seed' => sub {
    my ($o, $e, $code) = run($binbacktest, '--values', '5 5 9 5 9', '--min-train', '1', '--methods', 'last');
    is($code, 0, 'exit 0');
    unlike($o, qr/^markov1/, 'only last evaluated');

    ($o, $e, $code) = run($binbacktest, '--values', '5 5 9 5 9', '--min-train', '1', '--seed', '3');
    is($code, 0, 'exit 0 with seed');
    like($o, qr/^seed:\s+3$/m, 'seed shown');
    like($o, qr{^random\s+}m, 'random row present');
};

subtest 'backtest CLI --json' => sub {
    my ($o, $e, $code) = run($binbacktest, '--json', '--values', '5 5 9 5 9 5 9', '--min-train', '3', '--window', '0', '--methods', 'histogram');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{n}, 7, 'n');
    is($j->{positions}, 4, 'positions');
    is($j->{methods}[0]{method}, 'histogram', 'method in JSON');
    ok(defined $j->{methods}[0]{mae}, 'mae present');
    is($j->{methods}[0]{hit_rate}, 0.5, 'hit rate 2/4');
};

subtest 'random baseline requires a seed and never duplicates' => sub {
    my (undef, $e, $code) = run($binbacktest, '--values', '5 5 9 5 9', '--min-train', '1', '--methods', 'random');
    is($code, 2, 'random without --seed rejected');
    like($e, qr/requires --seed/, 'message');

    my ($o, undef, $code2) = run($binbacktest, '--values', '5 5 9 5 9', '--min-train', '1', '--methods', 'random', '--seed', '3');
    is($code2, 0, 'random with --seed ok');
    my $rows = () = $o =~ /^random\s+/mg;
    is($rows, 1, 'exactly one random row (no duplication)');

    (my $jo, undef, $code2) = run($binbacktest, '--json', '--values', '5 5 9 5 9', '--min-train', '1', '--methods', 'random', '--seed', '3');
    is($code2, 0, 'json ok');
    my $j = eval { JSON::PP::decode_json($jo) };
    ok($j, 'valid JSON');
    my $random_rows = grep { $_->{method} eq 'random' } @{ $j->{methods} };
    is($random_rows, 1, 'one random entry in JSON');
};

subtest 'backtest CLI errors and dispatch' => sub {
    my (undef, $e, $code) = run($binbacktest, '--values', '7');
    is($code, 1, 'too few values exit 1');

    (undef, $e, $code) = run($binbacktest, '--values', '1 2 3', '--methods', 'bogus');
    is($code, 2, 'unknown method exit 2');

    (undef, $e, $code) = run($binbacktest);
    is($code, 2, 'no input exit 2');

    my ($o, undef, $code2) = run($binbacktest, '--help');
    is($code2, 0, 'help exit 0');
    like($o, qr/rolling historical evaluation/, 'help text');

    ($o, undef, $code) = run($tubular, 'backtest', '--values', '5 5 9 5 9 5 9', '--min-train', '3');
    is($code, 0, 'tubular backtest works');
    like($o, qr/^markov1/m, 'dispatch shows metrics');
};

done_testing;