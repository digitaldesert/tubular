use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

my $root = dirname($RealBin);

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

my @bins = qw(doctor fetch extract inspect stats models forecast backtest);

subtest '--help works on every command' => sub {
    for my $b (@bins) {
        my ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', $b), '--help');
        is($code, 0, "$b --help exits 0"), next if $code != 0;
        like($o, qr/Usage:/, "$b --help shows usage");
    }
};

subtest '--json works on every data command' => sub {
    my $home = tempdir(CLEANUP => 1);
    local $ENV{TUBULAR_HOME} = $home;
    my $seq = File::Spec->catfile($root, 'examples', 'sequence.txt');

    my ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'inspect'), '--json', $seq);
    is($code, 0, 'inspect --json exits 0');
    ok(eval { JSON::PP::decode_json($o) }, 'inspect --json valid');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'stats'), '--json', $seq);
    is($code, 0, 'stats --json exits 0');
    ok(eval { JSON::PP::decode_json($o) }, 'stats --json valid');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'forecast'), '--json', '--values', '1 2 1 3');
    is($code, 0, 'forecast --json exits 0');
    ok(eval { JSON::PP::decode_json($o) }, 'forecast --json valid');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'forecast'), '--json', '--values', '1 2 1 3 4 4', '--ensemble', '--min-train', '2');
    is($code, 0, 'forecast --ensemble --json exits 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'ensemble --json valid');
    is($j->{mode}, 'ensemble', 'ensemble mode in JSON');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'backtest'), '--json', '--values', '5 5 9 5 9', '--min-train', '2');
    is($code, 0, 'backtest --json exits 0');
    ok(eval { JSON::PP::decode_json($o) }, 'backtest --json valid');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'models'), '--json', 'list');
    is($code, 0, 'models --json list exits 0');
    ok(eval { JSON::PP::decode_json($o) }, 'models --json valid');

    ($o, $e, $code) = run(File::Spec->catfile($root, 'bin', 'doctor'), '--json');
    is($code, 0, 'doctor --json exits 0');
    $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'doctor --json valid');
    ok(exists $j->{zsfm}{found}, 'doctor reports zsfm presence');
};

subtest 'end-to-end smoke via bin/tubular dispatcher' => sub {
    my $tubular = File::Spec->catfile($root, 'bin', 'tubular');

    my ($o, $e, $code) = run($tubular);
    is($code, 0, 'tubular with no args prints help');
    like($o, qr/Commands:/, 'command list shown');

    ($o, $e, $code) = run($tubular, '--version');
    is($code, 0, 'tubular --version exits 0');
    like($o, qr/^tubular \d+\.\d+ /, 'version string');

    ($o, $e, $code) = run($tubular, 'bogus-command');
    is($code, 2, 'unknown command exits 2');
    like($e, qr/unknown command/, 'diagnostic on stderr');
};

subtest 'missing-input failures are non-zero everywhere' => sub {
    my $missing = File::Spec->catfile($root, 't', 'definitely-missing.txt');
    for my $b (qw(inspect stats forecast backtest extract)) {
        my (undef, undef, $code) = run(File::Spec->catfile($root, 'bin', $b), $missing);
        isnt($code, 0, "$b missing input non-zero");
    }
};

done_testing;