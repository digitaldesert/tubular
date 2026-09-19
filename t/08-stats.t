use v5.44;
use warnings;
use Test::More;
use FindBin qw($RealBin);

use lib "$RealBin/../lib";
use tubular::Stats;

# Hand-verifiable checks. A: 10 20 30 40 50

subtest 'overview' => sub {
    my $s = tubular::Stats->analyze([ 10, 20, 30, 40, 50 ]);
    is($s->{ok}, 1, 'ok');
    is($s->{n}, 5, 'count');
    is($s->{unique}, 5, 'unique');
    is($s->{min}, 10, 'min');
    is($s->{max}, 50, 'max');
    is($s->{range}, 40, 'range');
    is($s->{mean}, 30, 'mean');
    is($s->{median}, 30, 'median');
    is($s->{variance}, 200, 'population variance');
    my $sd = sqrt(200);
    ok(abs($s->{stddev} - $sd) < 1e-12, 'stddev = sqrt(variance)');
    is_deeply($s->{mode}, [], 'no mode when every value is unique');
};

subtest 'mode ties sorted' => sub {
    my $s = tubular::Stats->analyze([ 3, 2, 3, 2 ]);
    is_deeply($s->{mode}, [ 2, 3 ], 'both modes, ascending');
    my $s2 = tubular::Stats->analyze([ 7, 7, 7, 2, 2 ]);
    is_deeply($s2->{mode}, [ 7 ], 'single repeat mode');
};

subtest 'histogram: empirical probabilities sum to 1' => sub {
    my $s = tubular::Stats->analyze([ 10, 20, 30, 40, 50 ]);
    is(scalar @{ $s->{histogram} }, 5, 'five entries');
    my $sum = 0;
    $sum += $_->{p} for @{ $s->{histogram} };
    ok(abs($sum - 1) < 1e-12, 'probabilities sum to 1');
    is($s->{histogram}[0]{value}, 10, 'sorted by value ascending');
    is($s->{histogram}[4]{value}, 50, 'last is max value');
};

subtest 'input order is preserved in the values field' => sub {
    my $s = tubular::Stats->analyze([ 5, 1, 9, 2, 7 ]);
    is_deeply($s->{values}, [ 5, 1, 9, 2, 7 ], 'values never sorted');
    is($s->{histogram}[0]{value}, 1, 'histogram independently sorted');
};

subtest 'transitions (first and second order)' => sub {
    my $s = tubular::Stats->analyze([ 1, 2, 3, 1, 2 ]);
    my @t = @{ $s->{transitions} };
    is(scalar @t, 3, 'three unique pairs');
    is($t[0]{from}, 1, 'from 1');
    is($t[0]{to}, 2, 'to 2');
    is($t[0]{count}, 2, '1->2 seen twice');
    ok(abs($t[0]{p} - 1) < 1e-12, '1->2 is the only outgoing edge from 1');

    my @t2 = @{ $s->{transitions2} };
    is(scalar @t2, 3, 'three triples');
    is_deeply(
        { a => $t2[0]{a}, b => $t2[0]{b}, c => $t2[0]{c}, count => $t2[0]{count} },
        { a => 1, b => 2, c => 3, count => 1 },
        'triple (1,2)->3 counted once'
    );
};

subtest 'gaps' => sub {
    my $s = tubular::Stats->analyze([ 7, 9, 7, 1, 7, 9 ]);
    my @gaps = @{ $s->{gaps} };
    my ($g7) = grep { $_->{value} == 7 } @gaps;
    my ($g9) = grep { $_->{value} == 9 } @gaps;
    my ($g1) = grep { $_->{value} == 1 } @gaps;
    is_deeply($g7->{gap_history}, [ 2, 2 ], '7 at positions 1,3,5');
    is($g7->{avg_gap}, 2, '7 average gap');
    is($g7->{max_gap}, 2, '7 max gap');
    is($g7->{current_run}, 1, '7 last seen at position 5 of 6');
    is_deeply($g9->{gap_history}, [ 4 ], '9 at positions 2,6');
    is($g9->{current_run}, 0, '9 is the final value');
    is_deeply($g1->{gap_history}, [], 'value seen once has no gaps');
    is($g1->{current_run}, 2, '1 last seen two positions ago');
};

subtest 'recent window' => sub {
    my $s = tubular::Stats->analyze([ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 ], recent => 3);
    is($s->{recent}{window}, 3, 'window recorded');
    is_deeply([ map { $_->{value} } @{ $s->{recent}{counts} } ], [ 8, 9, 10 ], 'only last 3 values');
    my $s2 = tubular::Stats->analyze([ 1, 2, 3 ], recent => 100);
    is($s2->{recent}{window}, 3, 'window capped at n');
};

subtest 'mode ties sorted' => sub {
    my $s = tubular::Stats->analyze([ 3, 2, 3, 2 ]);
    is_deeply($s->{mode}, [ 2, 3 ], 'both modes, ascending');
};

subtest 'streaks' => sub {
    my $s = tubular::Stats->analyze([ 4, 4, 4, 2, 4, 4 ]);
    is($s->{streaks}{max}, 3, 'longest run is 3');
    is($s->{streaks}{current}, 2, 'current trailing run is 2');
    my %by_len = map { $_->{length} => $_->{count} } @{ $s->{streaks}{distribution} };
    is_deeply(\%by_len, { 1 => 1, 2 => 1, 3 => 1 }, 'one run of each length');
};

subtest 'simple deterministic output order' => sub {
    my $a = tubular::Stats->analyze([ 9, 3, 1 ]);
    my $b = tubular::Stats->analyze([ 9, 3, 1 ]);
    is_deeply($a, $b, 'identical inputs produce identical hashes');
};

subtest 'empty sequence' => sub {
    my $s = tubular::Stats->analyze([]);
    is($s->{ok}, 0, 'not ok');
    is($s->{error}, 'empty sequence', 'error set');
};

done_testing;