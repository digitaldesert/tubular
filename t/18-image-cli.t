use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use IO::Socket::INET ();
use JSON::PP ();
use MIME::Base64 ();
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Cwd ();

use lib "$RealBin/../lib";

my $root = dirname($RealBin);
my $binimage = File::Spec->catfile($root, 'bin', 'image');
my $tubular  = File::Spec->catfile($root, 'bin', 'tubular');

my $png64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
my $png   = MIME::Base64::decode_base64($png64);

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
    return ($out, $err, $? >> 8);
}

sub run_stdin ($input, @args) {
    my $err_rd = gensym();
    my $pid = open3(my $in, my $out_rd, $err_rd, $^X, @args);
    print {$in} $input;
    close $in;
    my $out = '';
    my $err = '';
    local $/;
    $out = <$out_rd> // '';
    $err = <$err_rd> // '';
    waitpid $pid, 0;
    return ($out, $err, $? >> 8);
}

my %S;
sub start_server ($handler, $log) {
    my $sock = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1', LocalPort => 0,
        Proto => 'tcp', Listen => 8, ReuseAddr => 1,
    ) or die "cannot listen: $!";
    $S{port} = $sock->sockport;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        $SIG{TERM} = sub { exit 0 };
        while (my $conn = $sock->accept()) {
            my $head = <$conn> // '';
            my $clen = 0;
            while (my $line = <$conn>) {
                $clen = $1 if $line =~ /^Content-Length:\s*(\d+)/i;
                last if $line =~ /^\s*$/;
                $head .= $line;
            }
            my $body = '';
            read $conn, $body, $clen if $clen > 0;
            my $res = $handler->($head, $body);
            $res = { status => 200, body => $res } if !ref $res;
            $res->{body} //= '';
            $res->{'content-type'} //= 'application/json';
            open my $lf, '>>:raw', $log or next;
            print {$lf} JSON::PP::encode_json({ head => $head, body => $body }), "\n";
            close $lf;
            my $ct = $res->{'content-type'};
            print {$conn} 'HTTP/1.0 ' . $res->{status} . " X\r\n"
                . "Content-Type: $ct\r\n"
                . 'Content-Length: ' . length($res->{body}) . "\r\n"
                . "Connection: close\r\n\r\n" . $res->{body};
            close $conn;
        }
        exit 0;
    }
    return ($pid, $S{port});
}

sub cleanup { kill 'TERM', $S{spid} if $S{spid} }
END { cleanup() }

$S{log} = File::Spec->catfile(tempdir(CLEANUP => 1), 'requests.log');

my $handler = sub ($head, $body) {
    my ($line) = split /\r?\n/, $head;
    if ($line =~ m{^GET /raw\.png HTTP/1\.1}) {
        return { status => 200, body => $png, 'content-type' => 'image/png' };
    }
    if ($line =~ m{^POST /v1/images/generations HTTP/1\.1}) {
        my $j = eval { JSON::PP::decode_json($body) };
        my $model = $j && ref $j eq 'HASH' && defined $j->{model} ? $j->{model} : '';
        if ($model eq 'mock/urlimg') {
            return { status => 200, body => '{"data":[{"url":"' . "http://127.0.0.1:$S{port}/raw.png"
                . '"}]}' };
        }
        if ($model eq 'mock/badmodel') {
            return { status => 400, body => '{"error":{"message":"Invalid image model: mock/badmodel. Use format: provider/model"}}' };
        }
        if ($model eq 'mock/many') {
            return { status => 200, body => '{"data":[{"b64_json":"' . $png64
                . '"},{"b64_json":"' . $png64 . '"}]}' };
        }
        if ($model eq 'mock/nodata') {
            return { status => 200, body => '{"data":[]}' };
        }
        if ($model eq 'mock/successqueue') {
            return { status => 200, body => '{"created":1,"wait_time":12,"queue_position":1,"data":[{"b64_json":"' . $png64 . '"}]}' };
        }
        if ($model eq 'mock/err503') {
            return { status => 503, body => '{"error":{"type":"service_unavailable","message":"No Horde workers can currently fulfill this request","code":"service_unavailable"}}' };
        }
        return { status => 200, body => '{"data":[{"b64_json":"' . $png64 . '"}]}' };
    }
    return { status => 404, body => 'unknown route', 'content-type' => 'text/plain' };
};

my ($spid, $sport) = start_server($handler, $S{log});
$S{spid} = $spid;

sub base { "http://127.0.0.1:$sport/v1" }

sub reqs {
    return [] unless -e $S{log};
    open my $fh, '<:raw', $S{log} or return [];
    my @out;
    while (my $line = <$fh>) {
        my $j = eval { JSON::PP::decode_json($line) };
        push @out, $j if ref $j eq 'HASH';
    }
    close $fh;
    return \@out;
}

sub last_body {
    my $r = reqs();
    return undef unless @$r;
    return $r->[-1]{body};
}

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG)};
$ENV{TUBULAR_HOME} = tempdir(CLEANUP => 1);
$ENV{PATH} = tempdir(CLEANUP => 1);
local $ENV{OMNIROUTE_API_KEY} = 'sk-cli-test';

subtest '--help' => sub {
    my ($o, $e, $code) = run($binimage, '--help');
    is($code, 0, 'exit 0');
    like($o, qr/Usage:/, 'usage shown');
    like($o, qr/OmniRoute/, 'mentions OmniRoute');
    like($o, qr/OMNIROUTE_API_KEY/, 'mentions the API key variable');
    like($o, qr/STDIN/, 'documents STDIN prompt');
};

subtest 'required arguments' => sub {
    my (undef, $e, $code) = run($binimage);
    is($code, 2, 'missing --model exits 2');
    like($e, qr/--model is required/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test');
    is($code, 2, 'missing prompt exits 2');
    like($e, qr/prompt is required/, 'diagnostic');
};

subtest 'unknown and invalid options' => sub {
    my (undef, $e, $code) = run($binimage, '--bogus', '--model', 'aihorde/Test', '--prompt', 'x');
    is($code, 2, 'unknown option exits 2');
    like($e, qr/unknown option/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--size', 'banana');
    is($code, 2, 'bad --size exits 2');
    like($e, qr/--size must be/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--width', '128');
    is($code, 2, 'width without height exits 2');
    like($e, qr/--width and --height must be given together/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--width', 'a', '--height', 'b');
    is($code, 2, 'non-integer width exits 2');
    like($e, qr/--width must be an integer/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--quality', 'extreme');
    is($code, 2, 'bad --quality exits 2');
    like($e, qr/--quality must be/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--format', 'tiff');
    is($code, 2, 'bad --format exits 2');
    like($e, qr/--format must be/, 'diagnostic');

    (undef, $e, $code) = run($binimage, '--model', 'aihorde/Test', '--prompt', 'x', '--n', '0');
    is($code, 2, '--n 0 exits 2');
    like($e, qr/--n must be >= 1/, 'diagnostic');
};

subtest 'generation from a --prompt argument' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'arg.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'a red car beside a lake',
        '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    like($o, qr/Generated image:/, 'success header');
    like($o, qr/Model:  aihorde\/Test/, 'model echoed');
    like($o, qr/File:   \Q$out\E/, 'file echoed');
    ok(-e $out, 'file written');
    open my $fh, '<:raw', $out or die "read $out: $!";
    local $/;
    is(<$fh>, $png, 'bytes match fixture');
    close $fh;
};

subtest 'prompt from STDIN' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'stdin.png');
    my ($o, $e, $code) = run_stdin("futuristic city at night\n",
        $binimage, '--model', 'aihorde/Test', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    like($o, qr/Generated image:/, 'success');
    my $body = eval { JSON::PP::decode_json(last_body()) };
    is($body->{prompt}, "futuristic city at night\n", 'stdin prompt used verbatim');
};

subtest '--prompt wins over STDIN' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'prec.png');
    my ($o, $e, $code) = run_stdin("stdin prompt",
        $binimage, '--model', 'aihorde/Test', '--prompt', 'argument prompt',
        '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $body = eval { JSON::PP::decode_json(last_body()) };
    is($body->{prompt}, 'argument prompt', '--prompt wins');
};

subtest 'prompt preserves unicode and newlines via STDIN' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'uni.png');
    my $want = "A caf\x{e9} at night\n\x{591c}\x{666f} scene";
    utf8::encode(my $bytes = $want);
    my ($o, $e, $code) = run_stdin($bytes,
        $binimage, '--model', 'aihorde/Test', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $body = eval { JSON::PP::decode_json(last_body()) };
    is($body->{prompt}, $want, 'unicode + multiline prompt preserved');
};

subtest 'request construction (model, n, size, auth)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'req.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--n', '2', '--size', '512x512',
        '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $r = reqs();
    my $j = eval { JSON::PP::decode_json($r->[-1]{body}) };
    is($j->{model}, 'aihorde/Test', 'model in request');
    is($j->{n}, 2, 'n in request');
    is($j->{size}, '512x512', 'size in request');
    like($r->[-1]{head}, qr{^POST /v1/images/generations HTTP/1\.1}, 'endpoint');
    like($r->[-1]{head}, qr/Authorization: Bearer sk-cli-test/i, 'API key header');
};

subtest 'width/height normalize to size' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'wh.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x',
        '--width', '1024', '--height', '768', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json(last_body()) };
    is($j->{size}, '1024x768', 'size normalized from width/height');
};

subtest 'format overrides extension and sent as output_format' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'img');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--format', 'jpg',
        '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    ok(-e "$dir/img.jpg", 'jpg extension used');
    my $j = eval { JSON::PP::decode_json(last_body()) };
    is($j->{output_format}, 'jpeg', 'output_format sent as jpeg');
};

subtest 'default output naming' => sub {
    my $wd = tempdir(CLEANUP => 1);
    my $old = Cwd::cwd();
    chdir $wd or die "chdir: $!";
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--base-url', base());
    chdir $old or die "chdir back: $!";
    is($code, 0, 'exit 0');
    my @files = grep { basename($_) =~ /^image-\d{8}-\d{6}\.png$/ }
        glob File::Spec->catfile($wd, '*');
    is(scalar @files, 1, 'one image-<stamp>.png written');
    open my $fh, '<:raw', $files[0] or die "read: $!";
    local $/;
    is(<$fh>, $png, 'bytes match');
    close $fh;
};

subtest 'multiple images produce numbered files' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/many', '--prompt', 'x', '--n', '2',
        '--output', File::Spec->catfile($dir, 'squirrel.png'), '--base-url', base());
    is($code, 0, 'exit 0');
    like($o, qr/Generated 2 images:/, 'summary counts');
    like($o, qr/squirrel-001\.png/, 'numbered file 1');
    like($o, qr/squirrel-002\.png/, 'numbered file 2');
    ok(-e File::Spec->catfile($dir, 'squirrel-001.png'), 'file 1 exists');
    ok(-e File::Spec->catfile($dir, 'squirrel-002.png'), 'file 2 exists');
};

subtest 'fewer images than requested is warned' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/many', '--prompt', 'x', '--n', '3',
        '--output', File::Spec->catfile($dir, 's.png'), '--base-url', base());
    is($code, 0, 'still exits 0');
    like($e, qr/requested 3 images but OmniRoute returned 2/, 'warning on stderr');
};

subtest 'URL image response is downloaded' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'url.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/urlimg', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    ok(-e $out, 'file written');
    open my $fh, '<:raw', $out or die "read: $!";
    local $/;
    is(<$fh>, $png, 'downloaded bytes');
    close $fh;
};

subtest 'refuses to overwrite unless --force' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'keep.png');
    open my $fh, '>', $out or die $!;
    print {$fh} 'STALE';
    close $fh;
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'refused exits 1');
    like($e, qr/--force/, 'suggests --force');
    open my $rfh, '<', $out or die $!;
    local $/;
    is(<$rfh>, 'STALE', 'existing file untouched');
    close $rfh;

    ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out,
        '--force', '--base-url', base());
    is($code, 0, 'force succeeds');
    open my $ffh, '<:raw', $out or die $!;
    local $/;
    is(<$ffh>, $png, 'file replaced');
    close $ffh;
};

subtest 'API error exits 1 with useful message' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/badmodel', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    like($e, qr/HTTP 400/, 'status reported');
    like($e, qr/Invalid image model: mock\/badmodel/, 'API message reported');
    ok(!-e $out, 'no output file on API error');
};

subtest 'missing image data exits 1' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/nodata', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    like($e, qr/no image data/, 'clear error');
};

subtest 'queue info displayed after success' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'q.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/successqueue', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    like($o, qr/Queue:  position 1/, 'queue position printed');
    like($o, qr/Wait:   ~12 seconds/, 'wait time printed');
    ok(-e $out, 'file still written');
};

subtest 'queue info in --json output' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'qj.png');
    my ($o, $e, $code) = run($binimage,
        '--json', '--model', 'mock/successqueue', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{queue_position}, 1, 'queue_position present');
    is($j->{wait_time}, 12, 'wait_time present');
};

subtest 'worker-unavailable error is explained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/err503', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    like($e, qr/HTTP 503/, 'status');
    like($e, qr/service_unavailable/, 'error code');
    like($e, qr/run in a queue/, 'queue hint');

    ($o, $e, $code) = run($binimage,
        '--json', '--model', 'mock/err503', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'json exit 1');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON error');
    is($j->{error_code}, 'service_unavailable', 'structured code in JSON');
    like($j->{error}, qr/run in a queue/, 'hint in JSON error');
};

subtest 'missing OMNIROUTE_API_KEY exits 1' => sub {
    local $ENV{OMNIROUTE_API_KEY};
    delete $ENV{OMNIROUTE_API_KEY};
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    like($e, qr/OMNIROUTE_API_KEY is not set/, 'actionable error');
};

subtest 'API key never leaks' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/badmodel', '--prompt', 'x', '--output', $out, '--base-url', base());
    unlike($o, qr/sk-cli-test/, 'stdout clean');
    unlike($e, qr/sk-cli-test/, 'stderr clean');
};

subtest '--json success' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'j.png');
    my ($o, $e, $code) = run($binimage,
        '--json', '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{ok}, 1, 'ok flag');
    is($j->{bin}, 'image', 'bin named');
    is($j->{model}, 'aihorde/Test', 'model echoed');
    is($j->{images}[0]{file}, $out, 'file path in JSON');
    is($j->{images}[0]{ext}, 'png', 'ext in JSON');
    unlike($o, qr/sk-cli-test/, 'no key in JSON');
};

subtest '--json error' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'j.png');
    my ($o, $e, $code) = run($binimage,
        '--json', '--model', 'mock/badmodel', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON error');
    is($j->{ok}, 0, 'ok false');
    like($j->{error}, qr/Invalid image model/, 'error message');
};

subtest 'dispatches through bin/tubular' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'd.png');
    my ($o, $e, $code) = run($tubular, 'image',
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    ok(-e $out, 'file written through dispatcher');
};

done_testing;