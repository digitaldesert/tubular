use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use FindBin qw($RealBin);
use JSON::PP;
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

use lib "$RealBin/../lib";

my $root = dirname($RealBin);
my $tubular = File::Spec->catfile($root, 'bin', 'tubular');

sub run_tubular (@args) {
    my $err_rd = gensym();
    my $pid = open3(my $in, my $out_rd, $err_rd, $^X, $tubular, @args);
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

subtest '--help' => sub {
    my ($out, $err, $code) = run_tubular('--help');
    is($code, 0, 'help exits 0');
    like($out, qr/Usage:/, 'help text mentions usage');
    like($out, qr/doctor/, 'help lists commands');
};

subtest '-h alias' => sub {
    my ($out, $err, $code) = run_tubular('-h');
    is($code, 0, '-h exits 0');
};

subtest 'no arguments -> usage' => sub {
    my ($out, $err, $code) = run_tubular();
    is($code, 0, 'no args shows usage and exits 0');
    like($out, qr/Usage:/, 'usage shown');
};

subtest '--version' => sub {
    my ($out, $err, $code) = run_tubular('--version');
    is($code, 0, 'version exits 0');
    like($out, qr/^tubular 0\.1/, 'version printed');
};

subtest 'unknown command' => sub {
    my ($out, $err, $code) = run_tubular('frobnicate');
    isnt($code, 0, 'unknown command exits non-zero');
    like($err, qr/unknown command 'frobnicate'/, 'error names the command on stderr');
};

subtest 'tubular doctor dispatches' => sub {
    my ($out, $err, $code) = run_tubular('doctor');
    is($code, 0, 'doctor runs via tubular');
    like($out, qr/environment report/, 'doctor output produced');
    like($out, qr/v5\.44/, 'perl version reported');
};

subtest 'doctor --json through tubular' => sub {
    my ($out, $err, $code) = run_tubular('doctor', '--json');
    is($code, 0, 'doctor --json exits 0');
    my $json = eval { JSON::PP::decode_json($out) };
    ok($json, 'doctor --json prints valid JSON');
    ok(exists $json->{modules}, 'modules key present');
    ok(exists $json->{zsfm}, 'zsfm key present');
    ok(exists $json->{perl_version}, 'perl_version key present');
    ok(exists $json->{config_file}, 'config_file key present');
};

subtest 'tubular equals standalone' => sub {
    my ($out1, $err1, $code1) = run_tubular('doctor', '--json');
    my $script = File::Spec->catfile($root, 'bin', 'doctor');
    my $out2 = '';
    open my $fh, '-|', $^X, $script, '--json' or die "cannot run doctor: $!";
    local $/;
    $out2 = <$fh> // '';
    close $fh;
    my $code2 = $? >> 8;
    is($code1, $code2, 'same exit code');
    is($out1, $out2, 'identical output via tubular and standalone');
};

done_testing;