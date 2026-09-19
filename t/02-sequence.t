use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use FindBin qw($RealBin);

use lib "$RealBin/../lib";
use tubular::Sequence;

my $root = dirname($RealBin);

subtest 'basic string formats' => sub {
    my $a = tubular::Sequence->from_string('1 2 3 4');
    is($a->count, 4, 'space separated');
    is_deeply([$a->values], [1, 2, 3, 4], 'values parsed');

    my $b = tubular::Sequence->from_string('1,2,3,4');
    is($b->count, 4, 'comma separated');
    is_deeply([$b->values], [1, 2, 3, 4], 'comma values parsed');

    my $c = tubular::Sequence->from_string("1 2,3\n4");
    is_deeply([$c->values], [1, 2, 3, 4], 'mixed commas and whitespace');

    my $d = tubular::Sequence->from_string("1, 2\n3 \t 4,,5");
    is_deeply([$d->values], [1, 2, 3, 4, 5], 'mixed separators incl repeated commas');
};

subtest 'one number per line / file' => sub {
    my $f = tubular::Sequence->from_file(File::Spec->catfile($root, 'examples', 'sequence.txt'));
    is($f->count, 51, 'example.txt line count');
    is($f->source, 'file:' . File::Spec->catfile($root, 'examples', 'sequence.txt'), 'file source recorded');
    is($f->values->[0], 3, 'first value');
    is($f->values->[-1], 7, 'last value');
};

subtest 'order is preserved, never sorted' => sub {
    my $s = tubular::Sequence->from_string('10 2 30 4 50');
    is_deeply([$s->values], [10, 2, 30, 4, 50], 'no silent sort');
};

subtest 'floats negatives and scientific' => sub {
    my $s = tubular::Sequence->from_string('1.5 -2 .25 1e3 2E-2 +7');
    is_deeply([$s->values], [1.5, -2, 0.25, 1000, 0.02, 7], 'numeric forms accepted');
};

subtest 'min max unique' => sub {
    my $s = tubular::Sequence->from_string('3 7 12 7 9 3');
    is($s->min, 3, 'min');
    is($s->max, 12, 'max');
    is($s->unique_count, 4, 'unique count {3,7,9,12}');
    is(scalar @{ $s->warnings }, 0, 'no warnings');
};

subtest 'strict mode rejects malformed' => sub {
    eval { tubular::Sequence->from_string('1 2 x 4') };
    like($@, qr/malformed number token 'x'/, 'strict dies on bad token');
    ok(!defined $@ || $@ !~ /Strict/, 'explicit strict default');

    eval { tubular::Sequence->from_string('1 2 3.4.5 6') };
    like($@, qr/malformed number token '3\.4\.5'/, 'garbage rejected');

    eval { tubular::Sequence->from_string('1 xxx') };
    like($@, qr/malformed number token 'xxx'/, 'word rejected');
};

subtest 'lenient mode skips and warns' => sub {
    my $s = tubular::Sequence->from_string('1 x 2 y 3', strict => 0);
    is_deeply([$s->values], [1, 2, 3], 'lenient skips malformed');
    is($s->count, 3, 'count after skipping');
    is(scalar @{ $s->warnings }, 2, 'two warnings recorded');
    is($s->has_warnings, 1, 'has_warnings true');
};

subtest 'empty and degenerate' => sub {
    my $e = tubular::Sequence->from_string('');
    is($e->count, 0, 'empty string yields empty sequence');

    eval { $e->min };
    like($@, qr/min\(\) on empty sequence/, 'min on empty dies');

    eval { $e->max };
    like($@, qr/max\(\) on empty sequence/, 'max on empty dies');
};

subtest 'tokens preserve original spelling' => sub {
    my $s = tubular::Sequence->from_string('03 7 1.0');
    is_deeply([$s->tokens], ['03', '7', '1.0'], 'original tokens kept');
    is_deeply([$s->values], [3, 7, 1], 'values numified');
};

subtest 'constructor values' => sub {
    my $s = tubular::Sequence->new(values => [5, 1, 9], source => 'test');
    is($s->count, 3, 'constructed from array');
    is($s->source, 'test', 'source recorded');
    is($s->unique_count, 3, 'unique count');
    is($s->min, 1, 'min');
    is($s->max, 9, 'max');

    eval { tubular::Sequence->new(values => [1, 'junk']) };
    like($@, qr/must be numeric/, 'non-numeric constructor values rejected');
};

subtest 'from_file missing file' => sub {
    eval { tubular::Sequence->from_file('/does/not/exist.txt') };
    like($@, qr/no such file/, 'missing file dies');
};

done_testing;