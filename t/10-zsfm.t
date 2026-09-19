use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Time::HiRes qw(time);

use lib "$RealBin/../lib";
use tubular::Adapter::ZSFM;

# A fake zsfm that mirrors the ACTUAL installed CLI contract:
#   zsfm [--version | --help]
#   zsfm <model> --help
#   zsfm <model> infer --gguf <path>   (JSON request on stdin, OpenAI-style
#                                      JSON forecast on stdout)
sub write_fake ($dir, $name) {
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>', $path or die $!;
    print {$fh} "#!$^X\n";
    print {$fh} <<'PERL';
use v5.44;
use warnings;
use JSON::PP ();
sub mode { $ENV{MOCK_ZSFM_MODE} // 'normal' }

if (@ARGV == 1 && $ARGV[0] eq '--version') {
    if (exists $ENV{MOCK_NO_VERSION}) {
        print STDERR "error: unexpected argument '--version' found\n";
        exit 2;
    }
    print "zsfm 0.9.9 (mock)\n";
    exit 0;
}
if (@ARGV == 1 && $ARGV[0] eq '--help') {
    print "Zero-shot foundation models - mock\n\nUsage: zsfm <COMMAND>\n";
    exit 0;
}
if (@ARGV == 2 && $ARGV[0] eq 'timesfm' && $ARGV[1] eq '--help') {
    print "TimesFM 2.5 200M (mock) zero-shot time-series forecaster\n";
    exit 0;
}
if (@ARGV >= 3 && $ARGV[0] eq 'timesfm' && $ARGV[1] eq 'infer' && $ARGV[2] eq '--gguf') {
    my $gguf = $ARGV[3];
    my $req = JSON::PP::decode_json(do { local $/; <STDIN> });
    my $m = mode();
    if ($m eq 'sleep')    { sleep 20 }
    if ($m eq 'badjson')  { print "not json\n"; exit 0 }
    if ($m eq 'empty')    { exit 0 }
    if ($m eq 'fail')     { print STDERR "boom\n"; exit 1 }
    if ($m eq 'noforecast') { print "{\"model\":\"mock\"}\n"; exit 0 }

    my $horizon  = $req->{horizon} // 1;
    my $expected = $req->{context};
    my @point;
    if ($m eq 'wronglen') {
        @point = (40, 41);    # one more point than requested horizon
    }
    else {
        @point = map { 40 + $_ } 1 .. $horizon;
    }
    my %quant;
    if ($m ne 'pointonly') {
        $quant{quantiles} = {
            '0.1' => [ map { 39 + $_ } 1 .. $horizon ],
            '0.5' => [ @point ],
            '0.9' => [ map { 43 + $_ } 1 .. $horizon ],
        };
    }
    my %obj = (
        object         => 'forecast.points',
        point          => $m eq 'pointonly' ? \@point : [ \@point ],
        point_length   => scalar @point,
        context_length => scalar @$expected,
        frequency      => 'D',
        %quant,
    );
    my $out = {
        forecast => [ \%obj ],
        model    => 'mock/timesfm',
        gguf     => $gguf,
        argv     => [ @ARGV ],
        request  => $req,
    };
    if ($m eq 'stderr-ok') { print STDERR "mock diagnostic noise\n" }
    print JSON::PP->new->utf8->canonical->encode($out), "\n";
    exit 0;
}
print STDERR "unknown mock invocation: @ARGV\n";
exit 2;
PERL
    chmod 0755, $path;
    return $path;
}

sub gguf_file ($dir, @dirs) {
    my $target = $dir;
    for my $d (@dirs) {
        $target = File::Spec->catdir($target, $d);
        mkdir $target unless -d $target;
    }
    my $path = File::Spec->catfile($target, 'model.gguf');
    open my $fh, '>:raw', $path or die "write: $!";
    print {$fh} 'GGUF\x00fake-model';
    close $fh;
    return $path;
}

my $dir = tempdir(CLEANUP => 1);
my $fake = write_fake($dir, 'zsfm-mock');
my $gguf = gguf_file($dir);
my $space_gguf = gguf_file($dir, 'My Models', 'timesfm q8');

my $binless = tempdir(CLEANUP => 1);
my $orig_path = $ENV{PATH};

sub hermetic_path {
    $ENV{PATH} = "$dir:$binless";
}

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_ZSFM)};
$ENV{TUBULAR_INTEGRATION} = '1';
delete @ENV{qw(MOCK_ZSFM_MODE MOCK_NO_VERSION)};
hermetic_path();

subtest 'find through TUBULAR_ZSFM' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new;
    is($z->find(), $fake, 'locates explicit env path');
};

subtest 'find through PATH' => sub {
    delete $ENV{TUBULAR_ZSFM};
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new(runner => 'zsfm-mock');
    my $found = $z->find();
    is($found, File::Spec->catfile($dir, 'zsfm-mock'), 'paths are not shell-interpolated');
};

subtest 'find returns undef when absent' => sub {
    delete $ENV{TUBULAR_ZSFM};
    $ENV{PATH} = $binless;
    my $z = tubular::Adapter::ZSFM->new;
    is($z->find(), undef, 'none found');
    my $a = $z->available();
    ok(!$a->{ok}, 'available() reports not found');
    like($a->{error}, qr/not found/, 'availability error explains');
    my $v = $z->version();
    is($v->{ok}, 0, 'version fails');
    like($v->{error}, qr/not found/, 'version error explains');
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'forecast refuses when zsfm absent');
    like($res->{error}, qr/not found/, 'forecast error explains');
    $ENV{PATH} = "$dir:$binless";
};

subtest 'explicit path wins' => sub {
    my $z = tubular::Adapter::ZSFM->new(path => $fake);
    is($z->find(), $fake, 'path honoured');
};

subtest 'available() with binary' => sub {
    delete $ENV{TUBULAR_ZSFM};
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new(runner => 'zsfm-mock');
    my $a = $z->available();
    ok($a->{ok}, 'available with binary');
    is($a->{path}, File::Spec->catfile($dir, 'zsfm-mock'), 'path reported');
};

subtest 'version reports mock output' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new;
    my $v = $z->version();
    is($v->{ok}, 1, 'version ok');
    like($v->{version}, qr/zsfm 0\.9\.9/, 'version string');
    is($v->{exit}, 0, 'exit 0');
};

subtest 'version falls back to --help when --version unsupported' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    $ENV{MOCK_NO_VERSION} = 1;
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new;
    my $v = $z->version();
    is($v->{ok}, 1, 'identified via help, not a failure');
    is($v->{version}, undef, 'no version string available');
    like($v->{ident}, qr/Zero-shot foundation models/, 'help-derived identification');
    like($v->{note}, qr/--help/, 'note explains the fallback');
    delete $ENV{MOCK_NO_VERSION};
};

subtest 'supports_model probes the subcommand' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    my $z = tubular::Adapter::ZSFM->new;
    my $ts = $z->supports_model('timesfm');
    ok($ts->{ok}, 'timesfm supported');
    my $no = $z->supports_model('bogus');
    ok(!$no->{ok}, 'bogus model rejected');
    like($no->{error}, qr/no 'bogus' subcommand/, 'error explains');
    my $bad = $z->supports_model('../evil');
    ok(!$bad->{ok}, 'unsafe model name rejected');
};

subtest 'forecast roundtrip with normalized response' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1, 2, 3], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok($res->{ok}, 'forecast ok');
    is($res->{exit}, 0, 'exit 0');
    is_deeply($res->{result}{point}, [41], 'point series from nested OpenAI-style payload');
    is_deeply($res->{result}{quantiles}{'0.5'}, [41], 'quantiles normalized');
    is_deeply($res->{result}{quantiles}{'0.1'}, [40], 'lower quantile');
    is($res->{result}{model}, 'mock/timesfm', 'model echoed');
    ok(defined $res->{runtime_ms} && $res->{runtime_ms} >= 0, 'runtime_ms reported');
    is($res->{result}{raw_model}{request}{context}[0], 1, 'raw payload preserved for debugging');
};

subtest 'point-only response (no quantiles) is accepted' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    $ENV{MOCK_ZSFM_MODE} = 'pointonly';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1, 2], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok($res->{ok}, 'point-only forecast ok');
    is_deeply($res->{result}{point}, [41], 'flat point series accepted');
    is($res->{result}{quantiles}, undef, 'quantiles absent, nothing invented');
    delete $ENV{MOCK_ZSFM_MODE};
};

subtest 'gguf path containing spaces reaches argv intact' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $space_gguf });
    ok($res->{ok}, 'spacey path forecast ok');
    is($res->{result}{raw_model}{gguf}, $space_gguf, 'spacey gguf seen by the child process');
    is($res->{result}{raw_model}{argv}[2], '--gguf', 'argv layout: subcommand then flag');
    is($res->{result}{raw_model}{argv}[3], $space_gguf, 'no shell quoting applied');
    is($res->{gguf}, $space_gguf, 'result reports resolved gguf');
};

subtest 'integration gate refuses real run by default' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    delete $ENV{TUBULAR_INTEGRATION};
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'refused');
    like($res->{error}, qr/TUBULAR_INTEGRATION/, 'error names the gate');
    ok(exists $res->{path}, 'path still reported');
    $ENV{TUBULAR_INTEGRATION} = '1';
};

subtest 'request validation' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;

    my $r = $z->forecast({ context => [], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$r->{ok}, 'empty context rejected');
    like($r->{error}, qr/empty/, 'error explains');

    $r = $z->forecast({ context => [1, 'x'], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$r->{ok}, 'non-numeric context rejected');
    like($r->{error}, qr/only numbers/, 'error explains');

    for my $h (0, -1, 'abc', '1.5') {
        $r = $z->forecast({ context => [1], model => 'timesfm', horizon => $h, gguf => $gguf });
        ok(!$r->{ok}, "invalid horizon '$h' rejected");
        like($r->{error}, qr/positive integer/, 'error explains');
    }

    $r = $z->forecast({ context => [1], model => 'timesfm', horizon => 1 });
    ok(!$r->{ok}, 'missing gguf rejected');
    like($r->{error}, qr/GGUF model path/, 'error explains');

    $r = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => '/nonexistent/x.gguf' });
    ok(!$r->{ok}, 'missing gguf file rejected');
    like($r->{error}, qr/GGUF model not found/, 'error explains');

    for my $m ('../evil', 'has space', '--gguf', '') {
        $r = $z->forecast({ context => [1], model => $m, horizon => 1, gguf => $gguf });
        ok(!$r->{ok}, "unsafe model '$m' rejected");
        like($r->{error}, qr/invalid model name/, 'error explains')
            if $m ne '';
    }

    my $unreadable = gguf_file($dir, 'locked');
    chmod 0000, $unreadable;
    $r = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $unreadable });
    ok(!$r->{ok}, 'unreadable gguf rejected');
    like($r->{error}, qr/not readable/, 'error explains');
    chmod 0644, $unreadable;
};

subtest 'stderr on failed exit' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    $ENV{MOCK_ZSFM_MODE} = 'fail';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'failure detected');
    like($res->{error}, qr/exited 1/, 'exit code named');
    like($res->{error}, qr/boom/, 'stderr surfaced in error');
    like($res->{stderr}, qr/boom/, 'full stderr preserved on result');
    delete $ENV{MOCK_ZSFM_MODE};
};

subtest 'stderr on successful exit is preserved, not a failure' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    $ENV{MOCK_ZSFM_MODE} = 'stderr-ok';
    my $z = tubular::Adapter::ZSFM->new;
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok($res->{ok}, 'diagnostics on stderr do not fail a clean run');
    is($res->{exit}, 0, 'exit 0');
    like($res->{stderr}, qr/mock diagnostic noise/, 'stderr diagnostics carried for debug');
    delete $ENV{MOCK_ZSFM_MODE};
};

subtest 'malformed, empty and incomplete stdout' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    my $z = tubular::Adapter::ZSFM->new;

    $ENV{MOCK_ZSFM_MODE} = 'badjson';
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'invalid JSON detected');
    like($res->{error}, qr/invalid JSON/, 'error explains');
    delete $ENV{MOCK_ZSFM_MODE};

    $ENV{MOCK_ZSFM_MODE} = 'empty';
    $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'empty stdout detected');
    like($res->{error}, qr/no output on stdout/, 'error explains');
    delete $ENV{MOCK_ZSFM_MODE};

    $ENV{MOCK_ZSFM_MODE} = 'noforecast';
    $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'valid JSON without forecast data detected');
    like($res->{error}, qr/no forecast point series/, 'error explains');
    delete $ENV{MOCK_ZSFM_MODE};

    $ENV{MOCK_ZSFM_MODE} = 'wronglen';
    $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    ok(!$res->{ok}, 'point length mismatch detected');
    like($res->{error}, qr/expected 1 forecast points, got 2/, 'error explains');
    delete $ENV{MOCK_ZSFM_MODE};
};

subtest 'timeout is enforced' => sub {
    $ENV{TUBULAR_ZSFM} = $fake;
    hermetic_path();
    $ENV{TUBULAR_INTEGRATION} = '1';
    $ENV{MOCK_ZSFM_MODE} = 'sleep';
    my $z = tubular::Adapter::ZSFM->new(timeout => 1);
    my $t0 = time();
    my $res = $z->forecast({ context => [1], model => 'timesfm', horizon => 1, gguf => $gguf });
    my $elapsed = time() - $t0;
    ok(!$res->{ok}, 'times out');
    like($res->{error}, qr/timed out/, 'error explains');
    ok($elapsed < 10, "did not wait for the full sleep ($elapsed s)");
    delete $ENV{MOCK_ZSFM_MODE};
};

done_testing;

END { $ENV{PATH} = $orig_path }