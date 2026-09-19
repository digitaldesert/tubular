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

my $root = dirname($RealBin);
my $bininspect = File::Spec->catfile($root, 'bin', 'inspect');
my $binstats = File::Spec->catfile($root, 'bin', 'stats');
my $tubular = File::Spec->catfile($root, 'bin', 'tubular');
my $rootdir = File::Spec->catdir($root, 'examples');

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

subtest 'inspect --values summary' => sub {
    my ($o, $e, $code) = run($bininspect, '--values', '5 1 9 2 5');
    is($code, 0, 'exit 0');
    like($o, qr/^values:\s+5$/m, 'count');
    like($o, qr/^min\/max:\s+1 \/ 9$/m, 'min/max');
    like($o, qr/^mean:\s+4\.4$/m, 'mean');
};

subtest 'inspect reads examples/sequence.txt' => sub {
    my $file = File::Spec->catfile($rootdir, 'sequence.txt');
    my ($o, $e, $code) = run($bininspect, $file);
    is($code, 0, 'exit 0');
    like($o, qr/^source:\s+\Q$file\E$/m, 'source recorded');
    like($o, qr/^values:\s+51$/m, '51 values');
};

subtest 'inspect --json valid' => sub {
    my ($o, $e, $code) = run($bininspect, '--json', '--values', '10 20 30');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{n}, 3, 'n in JSON');
    is($j->{mean}, 20, 'mean in JSON');
    exists $j->{histogram} ? pass('histogram present') : fail('histogram present');
};

subtest 'stats --values human sections' => sub {
    my ($o, $e, $code) = run($binstats, '--values', '2 2 3 2');
    is($code, 0, 'exit 0');
    like($o, qr/Histogram \(empirical\)/, 'histogram section');
    like($o, qr/Recent window \(last \d+ values, empirical\)/, 'recent section');
    like($o, qr/First-order transitions \(empirical\)/, 'transitions section');
    like($o, qr/Streaks:/, 'streaks section');
};

subtest 'stats respects --recent' => sub {
    my ($o, $e, $code) = run($binstats, '--values', '1 2 3 4 5', '--recent', '2');
    is($code, 0, 'exit 0');
    like($o, qr/Recent window \(last 2 values, empirical\)/, 'window reported');
};

subtest 'stats --json contains labelled fields' => sub {
    my ($o, $e, $code) = run($binstats, '--json', '--values', '3 1 3');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is_deeply($j->{values}, [ 3, 1, 3 ], 'values in order');
    is($j->{mode}[0], 3, 'mode 3');
    ok(exists $j->{transitions2}, 'second-order transitions present');
    ok(exists $j->{gaps}, 'gaps present');
};

subtest 'stats reads CSV through extract options' => sub {
    my $file = File::Spec->catfile($root, 't', 'fixtures', 'multi.csv');
    my ($o, $e, $code) = run($binstats, $file, '--column', 'value');
    is($code, 0, 'exit 0');
    like($o, qr/^values:\s+3   unique:\s+3$/m, 'read via CSV column');
};

subtest 'missing input file exits 1' => sub {
    my ($o, $e, $code) = run($bininspect, File::Spec->catfile($root, 't', 'no-such-file.txt'));
    is($code, 1, 'exit 1');
    (undef, $e, $code) = run($binstats, File::Spec->catfile($root, 't', 'no-such-file.txt'));
    is($code, 1, 'stats exit 1 too')
};

subtest 'usage errors exit 2' => sub {
    my (undef, undef, $code) = run($bininspect, '--bogus');
    is($code, 2, 'inspect unknown option');
    (undef, undef, $code) = run($binstats, '--bogus');
    is($code, 2, 'stats unknown option');
    (undef, undef, $code) = run($bininspect);
    is($code, 2, 'inspect no input');
    (undef, undef, $code) = run($binstats, '--recent', '0');
    is($code, 2, 'stats bad recent');
    my ($o, $e, $code2) = run($bininspect, '--help');
    is($code2, 0, 'inspect help exits 0');
    like($o, qr/Usage:/, 'help shown');
};

subtest 'dispatch through bin/tubular' => sub {
    my ($o, undef, $code) = run($tubular, 'inspect', '--values', '7 14 21');
    is($code, 0, 'tubular inspect works');
    like($o, qr/^values:\s+3$/m, 'dispatch passes args');

    ($o, undef, $code) = run($tubular, 'stats', '--values', '7 14 21');
    is($code, 0, 'tubular stats works');
    like($o, qr/Histogram \(empirical\)/, 'stats dispatch prints sections');
};

done_testing;