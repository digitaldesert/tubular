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
my $binextract = File::Spec->catfile($root, 'bin', 'extract');
my $tubular = File::Spec->catfile($root, 'bin', 'tubular');
my $fix = File::Spec->catdir($root, 't', 'fixtures');

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

subtest '--help and usage errors' => sub {
    my ($o, $e, $code) = run($binextract, '--help');
    is($code, 0, 'help exits 0');
    like($o, qr/Usage:/, 'usage shown');

    ($o, $e, $code) = run($binextract);
    is($code, 2, 'no args exits 2');
    like($e, qr/Usage:/, 'usage on stderr');

    ($o, $e, $code) = run($binextract, '--bogus', 'x.csv');
    is($code, 2, 'unknown option exits 2');
    like($e, qr/unknown option/, 'option named');
};

subtest 'txt numbers to stdout' => sub {
    my $file = File::Spec->catfile($fix, 'numbers.txt');
    my ($o, $e, $code) = run($binextract, $file);
    is($code, 0, 'exit 0');
    is_deeply([ split /\n/, $o ], [ 3, 1, 4, 1, 5, 9, 2 ], 'one value per line');
};

subtest 'csv column by name via CLI' => sub {
    my $file = File::Spec->catfile($fix, 'multi.csv');
    my ($o, $e, $code) = run($binextract, $file, '--column', 'value');
    is($code, 0, 'exit 0');
    is_deeply([ split /\n/, $o ], [ 4, 8, 15 ], 'values in order');
};

subtest 'strict error exits non-zero' => sub {
    my $file = File::Spec->catfile($fix, 'bad.txt');
    my ($o, $e, $code) = run($binextract, $file);
    isnt($code, 0, 'strict failure exits 1');
    like($e, qr/xyz/, 'token named on stderr');

    my ($o2, $e2, $code2) = run($binextract, $file, '--strict', '0');
    is($code2, 0, 'non-strict exits 0');
    my @warn = grep { /warning/ } split /\n/, $e2;
    is(scalar @warn, 1, 'warning line on stderr');
};

subtest '--text mode emits raw text' => sub {
    my $file = File::Spec->catfile($fix, 'numbers.txt');
    my ($o, $e, $code) = run($binextract, $file, '--text');
    is($code, 0, 'exit 0');
    like($o, qr/9 2/, 'text output');
};

subtest '--json' => sub {
    my $file = File::Spec->catfile($fix, 'multi.csv');
    my ($o, $e, $code) = run($binextract, '--json', $file);
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{type}, 'csv', 'type echoed');
    is_deeply($j->{values}, [ 4, 8, 15 ], 'values in JSON');
    is_deeply($j->{header}, [ 'date', 'value', 'label' ], 'header in JSON');
};

subtest 'dispatches through bin/tubular' => sub {
    my $file = File::Spec->catfile($fix, 'numbers.txt');
    my ($o, $e, $code) = run($tubular, 'extract', $file);
    is($code, 0, 'tubular extract exits 0');
    is_deeply([ split /\n/, $o ], [ 3, 1, 4, 1, 5, 9, 2 ], 'values pass through dispatcher');
};

done_testing;