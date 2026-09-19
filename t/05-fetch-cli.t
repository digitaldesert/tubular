use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use IO::Socket::INET ();
use JSON::PP ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);

use lib "$RealBin/../lib";

my $root = dirname($RealBin);
my $binfetch = File::Spec->catfile($root, 'bin', 'fetch');
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

my $body = "the quick brown fox\njumps over\n";

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

my ($pid, $port);
END { kill 'TERM', $pid if $pid; }

my $handler = sub ($req) {
    my ($line) = split /\r?\n/, $req;
    return { status => 404, body => 'missing' } if $line =~ m{^GET /gone };
    return { status => 200, body => $body };
};
($pid, $port) = start_server($handler);

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG TUBULAR_HOME)};

my $url = "http://127.0.0.1:$port/data.bin";

subtest 'raw bytes to stdout without --output' => sub {
    my ($out, $err, $code) = run($binfetch, $url);
    is($code, 0, 'exit 0');
    is($out, $body, 'content on stdout');
    like($err, qr/sha256=[0-9a-f]{64}/, 'status line on stderr');
};

subtest '--output writes file' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'data.bin');
    my ($o, $e, $code) = run($binfetch, $url, '--output', $out);
    is($code, 0, 'exit 0');
    open my $fh, '<:raw', $out or die "no file: $!";
    local $/;
    my $got = <$fh>;
    close $fh;
    is($got, $body, 'file content matches');
    like($o, qr/fetched \d+ bytes/, 'status on stdout');
};

subtest '--output refuses to overwrite unless --force' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'data.bin');
    open my $fh, '>', $out or die $!;
    print {$fh} 'STALE';
    close $fh;
    my ($o, $e, $code) = run($binfetch, $url, '--output', $out);
    isnt($code, 0, 'refuses to overwrite');
    like($e, qr/--force/, 'error suggests --force');

    ($o, $e, $code) = run($binfetch, $url, '--output', $out, '--force');
    is($code, 0, 'force succeeds');
    open my $rfh, '<:raw', $out or die "no file: $!";
    local $/;
    is(<$rfh>, $body, 'file replaced');
    close $rfh;
};

subtest 'http error exits non-zero with message on stderr' => sub {
    my ($o, $e, $code) = run($binfetch, "http://127.0.0.1:$port/gone");
    isnt($code, 0, 'exit non-zero');
    like($e, qr/HTTP 404/, 'status named on stderr');
};

subtest '--json' => sub {
    my ($o, $e, $code) = run($binfetch, '--json', $url);
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{url}, $url, 'url echoed');
    is($j->{bytes}, length $body, 'bytes recorded');
    is($j->{ok}, JSON::PP::true(), 'ok true');
    ok($j->{bin} eq 'fetch', 'bin named');
    my $jerr = eval { JSON::PP::decode_json((run($binfetch, '--json', "http://127.0.0.1:$port/gone"))[0]) };
    ok($jerr, 'error path still valid JSON');
    is($jerr->{ok}, JSON::PP::false(), 'ok false');
};

subtest 'usage and option errors' => sub {
    my ($o, $e, $code) = run($binfetch);
    is($code, 2, 'missing URL exits 2');
    like($e, qr/Usage:/, 'usage shown on stderr');
    ($o, $e, $code) = run($binfetch, '--bogus', $url);
    is($code, 2, 'unknown option exits 2');
    like($e, qr/unknown option/, 'option named');
    ($o, $e, $code) = run($binfetch, '--help');
    is($code, 0, '--help exits 0');
    like($o, qr/Usage:/, 'help shown');
};

subtest 'dispatches through bin/tubular' => sub {
    my ($o, $e, $code) = run($tubular, 'fetch', $url);
    is($code, 0, 'tubular fetch exits 0');
    is($o, $body, 'content passed through dispatcher');
};

done_testing;