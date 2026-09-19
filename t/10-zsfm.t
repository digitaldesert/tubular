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

use lib "$RealBin/../lib";
use tubular::Adapter::ZSFM;

sub write_fake ($dir, $name, $mode) {
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>', $path or die $!;
    print {$fh} <<'PERL';
#!/usr/bin/env perl
use v5.44;
use warnings;
use JSON::PP ();
my $arg = shift;
if (defined $arg && $arg eq '--version') {
    print "zsfm 0.9.9 (mock)\n";
    exit 0;
}
if (defined $arg && $arg eq 'forecast') {
    my $in = do { local $/; <STDIN> };
    if (exists $ENV{MOCK_ZSFM_MODE} && $ENV{MOCK_ZSFM_MODE} eq 'sleep') { sleep 20 }
    if (exists $ENV{MOCK_ZSFM_MODE} && $ENV{MOCK_ZSFM_MODE} eq 'badjson') { print "not json\n"; exit 0 }
    if (exists $ENV{MOCK_ZSFM_MODE} && $ENV{MOCK_ZSFM_MODE} eq 'fail') { print STDERR "boom\n"; exit 1 }
    my $e = JSON::PP->new->utf8->canonical;
    print $e->encode({ forecast => [41], model => 'timesfm', dtype => 'q8', horizon => 1, request => $in });
    exit 0;
}
print STDERR "unknown mock command: @ARGV\n";
exit 2;
PERL
    chmod 0755, $path;
    return $path;
}

my $dir = tempdir(CLEANUP => 1);
my $fake = write_fake($dir, 'zsfm-mock', 'normal');

my $orig_path = $ENV{PATH};
local %ENV = %ENV;
delete @ENV{qw(TUBULAR_ZSFM)};
$ENV{TUBULAR_INTEGRATION} = '1';
$ENV{PATH} = $orig_path;

subtest 'find through TUBULAR_ZSFM' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    my $z = tubular::Adapter::ZSFM->new;
    is($z->find(), $fake, 'locates explicit env path');
};

subtest 'find through PATH' => sub {
    delete $ENV{TUBULAR_ZSFM};
    $ENV{PATH} = "$dir:$orig_path";
    my $z = tubular::Adapter::ZSFM->new(runner => 'zsfm-mock');
    my $found = $z->find();
    is($found, File::Spec->catfile($dir, 'zsfm-mock'), 'paths are not shell-interpolated');
    $ENV{PATH} = $orig_path;
};

subtest 'find returns undef when absent' => sub {
    delete $ENV{TUBULAR_ZSFM};
    my $empty = tempdir(CLEANUP => 1);
    $ENV{PATH} = $empty;
    my $z = tubular::Adapter::ZSFM->new;
    is($z->find(), undef, 'none found');
    my $v = $z->version();
    is($v->{ok}, 0, 'version fails');
    like($v->{error}, qr/not found/, 'error explains');
    $ENV{PATH} = $orig_path;
};

subtest 'explicit path wins' => sub {
    my $z = tubular::Adapter::ZSFM->new(path => $fake);
    is($z->find(), $fake, 'path honoured');
};

subtest 'version reports mock output' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    my $z = tubular::Adapter::ZSFM->new;
    my $v = $z->version();
    is($v->{ok}, 1, 'version ok');
    like($v->{version}, qr/zsfm 0\.9\.9/, 'version string');
    is($v->{exit}, 0, 'exit 0');
};

subtest 'forecast roundtrip with JSON' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1, 2, 3], model => 'timesfm', dtype => 'q8', horizon => 1 });
    ok($res->{ok}, 'forecast ok');
    is($res->{exit}, 0, 'exit 0');
    is($res->{result}{forecast}[0], 41, 'prediction decoded');
    like($res->{result}{request}, qr/"context":\[1,2,3\]/, 'request JSON echoed back unchanged');
    is($res->{result}{dtype}, 'q8', 'dtype passed through');
    is($res->{result}{model}, 'timesfm', 'model passed through');
};

subtest 'integration gate refuses real run by default' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    delete $ENV{TUBULAR_INTEGRATION};
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1], model => 'timesfm', dtype => 'q8', horizon => 1 });
    ok(!$res->{ok}, 'refused');
    like($res->{error}, qr/TUBULAR_INTEGRATION/, 'error names the gate');
    ok(exists $res->{path}, 'path still reported');
};

subtest 'non-zero exit and bad JSON' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;

    $ENV{MOCK_ZSFM_MODE} = 'fail';
    my $res = $z->forecast({ context => [1], model => 'timesfm', dtype => 'q8', horizon => 1 });
    ok(!$res->{ok}, 'failure detected');
    like($res->{error}, qr/exited 1/, 'exit code named');
    like($res->{stderr}, qr/boom/, 'stderr surfaced');
    delete $ENV{MOCK_ZSFM_MODE};

    $ENV{MOCK_ZSFM_MODE} = 'badjson';
    $res = $z->forecast({ context => [1], model => 'timesfm', dtype => 'q8', horizon => 1 });
    ok(!$res->{ok}, 'invalid JSON detected');
    like($res->{error}, qr/invalid JSON/, 'error explains');
    delete $ENV{MOCK_ZSFM_MODE};
};

subtest 'timeout is enforced' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{PATH} = $orig_path;
    $ENV{TUBULAR_INTEGRATION} = '1';
    $ENV{MOCK_ZSFM_MODE} = 'sleep';
    my $z = tubular::Adapter::ZSFM->new(timeout => 1);
    my $t0 = time();
    my $res = $z->forecast({ context => [1], model => 'timesfm', dtype => 'q8', horizon => 1 });
    my $elapsed = time() - $t0;
    ok(!$res->{ok}, 'times out');
    like($res->{error}, qr/timed out/, 'error explains');
    ok($elapsed < 10, "did not wait for the full sleep ($elapsed s)");
    delete $ENV{MOCK_ZSFM_MODE};
};

done_testing;