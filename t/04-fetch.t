use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use IO::Socket::INET ();
use Digest::SHA ();

use lib "$RealBin/../lib";
use tubular::Fetch;

my $root = dirname($RealBin);

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
                . "Content-Type: text/plain\r\n"
                . 'Content-Length: ' . length($res->{body}) . "\r\n"
                . "Connection: close\r\n\r\n" . $res->{body};
            close $conn;
        }
        exit 0;
    }
    return ($pid, $port);
}

sub kill_server ($pid) {
    return unless $pid;
    kill 'TERM', $pid;
    waitpid $pid, 0;
}

my ( $pid, $port );
sub cleanup {
    kill_server($pid);
}
END { cleanup() }

my @history;
my $body = "alpha,beta,gamma\n1,2,3\n4,5,6\n";
my $handler = sub ($req) {
    push @history, $req;
    my ($line) = split /\r?\n/, $req;
    return { status => 200, body => $req } if $line =~ m{^GET /echo };
    if ($line =~ m{^GET /slow }) {
        select undef, undef, undef, 3;
        return { status => 200, body => 'slow' };
    }
    return { status => 404, body => 'nope' } if $line =~ m{^GET /missing };
    return { status => 500, body => 'oops' } if $line =~ m{^GET /error500 };
    return { status => 200, body => $body };
};

($pid, $port) = start_server($handler);

sub url_of ($path) { "http://127.0.0.1:$port$path" }

subtest 'successful fetch' => sub {
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/ok'));
    ok($res->{ok}, 'ok');
    is($res->{http_status}, 200, 'status 200');
    is($res->{bytes}, length $body, 'byte count');
    ok($res->{sha256} =~ /^[0-9a-f]{64}$/, 'sha256 hex');
    ok(exists $res->{elapsed}, 'elapsed present');
};

subtest 'output written atomically' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'out.txt');
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/ok'), output => $out);
    ok($res->{ok}, 'ok');
    is($res->{output}, $out, 'output recorded');
    open my $fh, '<:raw', $out or die "no output file: $!";
    local $/;
    my $got = <$fh>;
    close $fh;
    is($got, $body, 'content written');
    my @leftover = glob File::Spec->catfile($dir, '.tubular-fetch.*.tmp');
    is(scalar @leftover, 0, 'no temp file left behind');
};

subtest 'no overwrite without force; force overwrites' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'out.txt');
    open my $fh, '>', $out or die $!;
    print {$fh} 'OLD';
    close $fh;

    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/ok'), output => $out);
    ok(!$res->{ok}, 'refused to overwrite');
    like($res->{error}, qr/--force/, 'error suggests --force');

    $res = $f->fetch(url_of('/ok'), output => $out, force => 1);
    ok($res->{ok}, 'force overwrote');
    open my $rfh, '<', $out or die $!;
    local $/;
    my $now = <$rfh>;
    close $rfh;
    is($now, $body, 'new content in place');
};

subtest 'http errors reported cleanly' => sub {
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/missing'));
    ok(!$res->{ok}, '404 not ok');
    like($res->{error}, qr/HTTP 404/, 'error mentions status');
    is($res->{http_status}, 404, 'status recorded');

    $res = $f->fetch(url_of('/error500'));
    ok(!$res->{ok}, '500 not ok');
    like($res->{error}, qr/HTTP 500/, '500 reported');
};

subtest 'sha256 verification' => sub {
    my $f = tubular::Fetch->new;
    my $good = Digest::SHA::sha256_hex($body);
    my $res = $f->fetch(url_of('/ok'), sha256 => $good);
    ok($res->{ok}, 'matching hash ok');

    my $bad = 'x' x 64;
    $res = $f->fetch(url_of('/ok'), sha256 => $bad);
    ok(!$res->{ok}, 'mismatch rejected');
    like($res->{error}, qr/SHA-256 mismatch/, 'error explains mismatch');
};

subtest 'max bytes enforced' => sub {
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/ok'), max_bytes => 10);
    ok(!$res->{ok}, 'too-small limit fails');
    like($res->{error}, qr/max_bytes/, 'error mentions limit');
};

subtest 'timeout' => sub {
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/slow'), timeout => 1);
    ok(!$res->{ok}, 'slow request fails on timeout');
};

subtest 'invalid and non-http urls' => sub {
    my $f = tubular::Fetch->new;
    my $res = $f->fetch('ftp://example.com/x');
    ok(!$res->{ok}, 'ftp rejected');
    like($res->{error}, qr/invalid URL/, 'error explains');
};

subtest 'request uses HTTP/1 line with user agent echoed back' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'echo.txt');
    my $f = tubular::Fetch->new;
    my $res = $f->fetch(url_of('/echo'), output => $out, user_agent => 'tubular-test/1.0');
    ok($res->{ok}, 'echo ok');
    open my $fh, '<', $out or die $!;
    local $/;
    my $echo = <$fh>;
    close $fh;
    like($echo, qr{^GET /echo HTTP/1.1}, 'sends HTTP/1.1 request line');
    like($echo, qr{^User-Agent: tubular-test/1.0\r?$}m, 'echoes configured user agent');
};

done_testing;