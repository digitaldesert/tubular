use v5.44;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Basename qw(dirname);
use JSON::PP ();
use FindBin qw($RealBin);

use lib "$RealBin/../lib";
use tubular::Config;

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};

my $root = dirname($RealBin);

sub write_cfg ($name, $json) {
    my $dir = tempdir(CLEANUP => 1);
    my $path = File::Spec->catfile($dir, $name);
    open my $fh, '>', $path or die "cannot write $path: $!";
    print {$fh} $json;
    close $fh;
    return $path;
}

subtest 'default project config' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $cfg = tubular::Config->new();
    ok($cfg->config_loaded, 'config loaded');
    is($cfg->project_root, $root, 'project root found');
    is($cfg->get('forecast', 'model'), 'timesfm', 'forecast.model default from config.json');
    is($cfg->get('fetch', 'timeout'), 30, 'fetch.timeout from config.json');
    is($cfg->get('home'), '.tubular', 'home default');
    ok(-e $cfg->config_path, 'config path exists');
};

subtest 'placed-module project root' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $root2 = File::Spec->rel2abs($root);
    is(tubular::Config->new()->project_root, $root2, 'root is absolute clean path');
};

subtest 'builtin defaults merge' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $partial = write_cfg('partial.json', qq|{"forecast": {"model": "chronos-2"}}|);
    local $ENV{TUBULAR_CONFIG} = $partial;
    my $cfg = tubular::Config->new();
    is($cfg->get('forecast', 'model'), 'chronos-2', 'override wins');
    is($cfg->get('forecast', 'horizon'), 1, 'default filled in');
    is($cfg->get('fetch', 'timeout'), 30, 'fetch defaults untouched');
    is($cfg->get('home'), '.tubular', 'home default present');
};

subtest 'unknown keys preserved' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $extra = write_cfg('extra.json', qq|{"future_phase_key": {"a": 1}}|);
    local $ENV{TUBULAR_CONFIG} = $extra;
    my $cfg = tubular::Config->new();
    is_deeply($cfg->get('future_phase_key'), { a => 1 }, 'unknown top-level key preserved');
};

subtest 'constructor overrides' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $cfg = tubular::Config->new(
        overrides => { fetch => { timeout => 5 } },
    );
    is($cfg->get('fetch', 'timeout'), 5, 'constructor override applied');
    is($cfg->get('fetch', 'max_bytes'), 52428800, 'other defaults remain');
};

subtest 'override method' => sub {
    my $cfg = tubular::Config->new(overrides => { fetch => { max_bytes => 10 } });
    $cfg->override('fetch.timeout' => 99);
    is($cfg->get('fetch', 'timeout'), 99, 'dotted override applied');
};

subtest 'TUBULAR_CONFIG missing file' => sub {
    local $ENV{TUBULAR_CONFIG} = '/nonexistent/config.json';
    eval { tubular::Config->new() };
    like($@, qr/TUBULAR_CONFIG/, 'dies on missing explicit config');
};

subtest 'invalid JSON' => sub {
    my $bad = write_cfg('bad.json', '{"fetch": ');
    local $ENV{TUBULAR_CONFIG} = $bad;
    eval { tubular::Config->new() };
    like($@, qr/invalid JSON/, 'invalid JSON rejected');
};

subtest 'non-object config' => sub {
    my $arr = write_cfg('arr.json', '[1,2,3]');
    local $ENV{TUBULAR_CONFIG} = $arr;
    eval { tubular::Config->new() };
    like($@, qr/JSON object/, 'array config rejected');
};

subtest 'structural validation' => sub {
    my $scalar_fetch = write_cfg('scalar_fetch.json', '{"fetch": 5}');
    local $ENV{TUBULAR_CONFIG} = $scalar_fetch;
    eval { tubular::Config->new() };
    like($@, qr/fetch must be an object/, 'scalar fetch rejected');

    my $bad_type = write_cfg('bad_type.json', '{"fetch": {"timeout": "soon"}}');
    local $ENV{TUBULAR_CONFIG} = $bad_type;
    eval { tubular::Config->new() };
    like($@, qr/fetch\.timeout must be numeric/, 'non-numeric timeout rejected');
};

subtest 'home override' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $cfg = tubular::Config->new(home => '/tmp/somehome');
    is($cfg->home, '/tmp/somehome', 'home constructor override');

    local $ENV{TUBULAR_HOME} = '/tmp/envhome';
    my $cfg2 = tubular::Config->new();
    is($cfg2->home, '/tmp/envhome', 'TUBULAR_HOME honored');

    delete $ENV{TUBULAR_HOME};
    my $cfg3 = tubular::Config->new();
    is($cfg3->home, "$root/.tubular", 'default home under project root');
};

subtest 'as_hash' => sub {
    local %ENV = %ENV;
    delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};
    my $cfg = tubular::Config->new();
    my $h = $cfg->as_hash();
    is(ref $h, 'HASH', 'as_hash returns hashref');
    ok(exists $h->{fetch}{timeout}, 'merged data exposed');
};

done_testing; # + subtests