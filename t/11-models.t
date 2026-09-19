use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use JSON::PP ();
use Digest::SHA ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use IO::Socket::INET ();

use lib "$RealBin/../lib";

my $root = dirname($RealBin);
my $binmodels = File::Spec->catfile($root, 'bin', 'models');
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

sub start_server ($handler) {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', Listen => 8, ReuseAddr => 1,
    ) or die "cannot listen: $!";
    my $port = $sock->sockport;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        $SIG{TERM} = sub { exit 0 };
        while (my $conn = $sock->accept()) {
            my $head = <$conn> // '';
            while (<$conn>) {
                $head .= $_;
                last if /^\r?\n$/;
            }
            my $res = $handler->($head);
            $res = { status => 200, body => $res } if !ref $res;
            $res->{body} //= '';
            print {$conn} 'HTTP/1.0 ' . $res->{status} . " X\r\n"
                . "Content-Type: application/octet-stream\r\n"
                . 'Content-Length: ' . length($res->{body}) . "\r\n"
                . "Connection: close\r\n\r\n" . $res->{body};
            close $conn;
        }
        exit 0;
    }
    return ($pid, $port);
}

my ($spid, $sport);
END { kill 'TERM', $spid if $spid }

my $gguf_bytes = "GGUF\x03HI\x00fake-model-bytes\x00";
my $gguf_sha = Digest::SHA::sha256_hex($gguf_bytes);

sub url_of ($path) { "http://127.0.0.1:$sport$path" }

($spid, $sport) = start_server(sub ($req) {
    my ($line) = split /\r?\n/, $req;
    return { status => 200, body => $gguf_bytes } if $line =~ m{^GET /};
    return { status => 404, body => 'missing' };
});

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG)};

my $home = tempdir(CLEANUP => 1);
$ENV{TUBULAR_HOME} = $home;

# Hermetic PATH: the offline suite must not observe a zsfm installed on the
# host. All child commands are run via the absolute perl binary.
$ENV{PATH} = tempdir(CLEANUP => 1);

my $models = File::Spec->catdir($home, 'models');

subtest 'list with no models' => sub {
    my ($o, $e, $code) = run($binmodels, 'list');
    is($code, 0, 'exit 0');
    like($o, qr/no models installed/, 'message shown');
};

subtest 'setup requires --url or --file' => sub {
    my (undef, $e, $code) = run($binmodels, 'setup', 'timesfm');
    is($code, 2, 'usage error exit 2');
    like($e, qr/needs exactly one of --url or --file/, 'message');
};

subtest 'invalid model names rejected' => sub {
    my (undef, $e, $code) = run($binmodels, 'setup', '../evil', '--file', 'x');
    is($code, 2, 'path traversal rejected');
    like($e, qr/invalid model name/, 'message');

    (undef, $e, $code) = run($binmodels, 'setup', 'has space', '--file', 'x');
    is($code, 2, 'space rejected');
    like($e, qr/invalid model name/, 'message');
};

subtest 'setup --file imports a local model' => sub {
    my $src = File::Spec->catfile($home, 'src.gguf');
    open my $fh, '>:raw', $src or die "write: $!";
    print {$fh} $gguf_bytes;
    close $fh;

    my ($o, $e, $code) = run($binmodels, 'setup', 'timesfm', '--file', $src);
    is($code, 0, 'exit 0');
    like($o, qr/installed timesfm/, 'message');
    like($o, qr/q8/, 'default dtype q8');

    my $file = File::Spec->catfile($models, 'timesfm-q8.gguf');
    ok(-e $file, 'model file copied');
    open my $mf, '<:raw', $file or die "read: $!";
    local $/;
    my $got = <$mf>;
    close $mf;
    is($got, $gguf_bytes, 'bytes preserved');

    my $man = JSON::PP::decode_json(do {
        open my $fh, '<:encoding(UTF-8)', File::Spec->catfile($models, 'timesfm.json') or die "read: $!";
        local $/; <$fh>;
    });
    is($man->{sha256}, $gguf_sha, 'manifest sha256 recorded');
    is($man->{file}, 'timesfm-q8.gguf', 'manifest file recorded');
};

subtest 'setup refuses to overwrite unless --force' => sub {
    my $src = File::Spec->catfile($home, 'src.gguf');
    my ($o, $e, $code) = run($binmodels, 'setup', 'timesfm', '--file', $src);
    is($code, 1, 'exit 1');
    like($o, qr/already installed/, 'refusal message');
};

subtest 'setup downloads via --url' => sub {
    my ($o, $e, $code) = run($binmodels, 'setup', 'nano', '--dtype', 'f16', '--url', url_of('/nano.gguf'));
    is($code, 0, 'exit 0');
    like($o, qr/installed nano/, 'message');
    my $file = File::Spec->catfile($models, 'nano-f16.gguf');
    ok(-e $file, 'downloaded file present');
    my $man = JSON::PP::decode_json(do {
        open my $fh, '<:encoding(UTF-8)', File::Spec->catfile($models, 'nano.json') or die "read: $!";
        local $/; <$fh>;
    });
    is($man->{sha256}, $gguf_sha, 'downloaded sha256 recorded');
    like($man->{source}, qr{^http://127\.0\.0\.1}, 'source URL recorded');
};

subtest 'path prints installed location' => sub {
    my ($o, $e, $code) = run($binmodels, 'path', 'timesfm');
    is($code, 0, 'exit 0');
    is($o, File::Spec->catfile($models, 'timesfm-q8.gguf') . "\n", 'exact path');
};

subtest 'path for missing model exits 1' => sub {
    my ($o, $e, $code) = run($binmodels, 'path', 'ghost');
    is($code, 1, 'exit 1');
    like($o, qr/not installed/, 'message');
};

subtest 'list shows the installed models' => sub {
    my ($o, $e, $code) = run($binmodels, 'list');
    is($code, 0, 'exit 0');
    my $prefix = substr($gguf_sha, 0, 6);
    like($o, qr/^timesfm\s+q8\s+25\s+\Q$prefix\E/m, 'timesfm row');
    like($o, qr/^nano\s+f16/m, 'nano row');
};

subtest 'status reports zsfm availability' => sub {
    my ($o, $e, $code) = run($binmodels, 'status');
    is($code, 0, 'exit 0');
    like($o, qr/run dir:/, 'dir shown');
    like($o, qr/zsfm:\s+not found/, 'zsfm not found (no real binary)');
    like($o, qr/installed:/, 'installed section');
    like($o, qr/timesfm/, 'model listed');

    my $fake = File::Spec->catfile($home, 'zsfm');
    open my $fh, '>:raw', $fake or die "write: $!";
    print {$fh} "#!$^X\nprint \"zsfm 9.9.9 (fake)\\n\";\nexit 0;\n";
    close $fh;
    chmod 0755, $fake;

    local $ENV{TUBULAR_ZSFM} = $fake;
    ($o, $e, $code) = run($binmodels, 'status');
    is($code, 0, 'exit 0 with fake zsfm');
    like($o, qr/zsfm:\s+\Q$fake\E \(zsfm 9\.9\.9/, 'version shown');
};

subtest 'json output parses' => sub {
    my ($o, $e, $code) = run($binmodels, '--json', 'status', 'timesfm');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{ok}, 1, 'ok flag');
    is($j->{command}, 'status', 'command field consistent');
    is($j->{model}{name}, 'timesfm', 'model name');
    is($j->{model}{present}, 1, 'present flag');
    is($j->{model}{sha256}, $gguf_sha, 'sha in JSON');
};

subtest 'status --json lists command field' => sub {
    my ($o, $e, $code) = run($binmodels, '--json', 'status');
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{command}, 'status', 'list-status carries command');
    is($j->{ok}, 1, 'ok flag');
};

subtest 'no command nor --help exits 2' => sub {
    my (undef, $e, $code) = run($binmodels);
    is($code, 2, 'no subcommand');
    my ($o, undef, $code2) = run($binmodels, '--help');
    is($code2, 0, 'help exit 0');
    like($o, qr/no implicit downloads/, 'help explains policy');
};

subtest 'dispatch through bin/tubular' => sub {
    my ($o, $e, $code) = run($tubular, 'models', 'list');
    is($code, 0, 'tubular models list works');
    like($o, qr/timesfm/, 'models visible via dispatch');
};

done_testing;