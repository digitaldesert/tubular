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
    if ($line =~ m{^(GET|DELETE) /(?:api/)?v2/generate/(check|status)/([^\s?]+) HTTP/1\.[01]}) {
        my ($method, $kind, $id) = ($1, $2, $3);
        if ($method eq 'DELETE') {
            return { status => 200, body => '{}' };
        }
        if ($kind eq 'check') {
            if ($id eq 'job-noworker') {
                return { status => 200, body => '{"done":false,"is_possible":false,"wait_time":0,"queue_position":0}' };
            }
            return { status => 200, body => '{"done":true,"wait_time":12,"queue_position":1,"is_possible":true}' };
        }
        if ($id eq 'job-censored') {
            return { status => 200, body => '{"generations":[{"img":"http://127.0.0.1:'
                . $S{port} . '/raw.png","censored":true}]}' };
        }
        if ($id =~ /^job-ok(?:-(\d+))?\z/) {
            my $n = defined $1 ? 0 + $1 : 1;
            $n = 1 if $n < 1;
            my $gen = '{"img":"http://127.0.0.1:' . $S{port} . '/raw.png"}';
            my $gens = join(',', ($gen) x $n);
            return { status => 200, body => '{"wait_time":12,"queue_position":1,"generations":[' . $gens . ']}' };
        }
        return { status => 200, body => '{"generations":[{"img":"http://127.0.0.1:'
            . $S{port} . '/raw.png"}]}' };
    }
    if ($line =~ m{^POST /(?:api/)?v2/generate/async HTTP/1\.[01]}) {
        my $j = eval { JSON::PP::decode_json($body) };
        my $model = '';
        if ($j && ref $j eq 'HASH' && ref $j->{models} eq 'ARRAY' && @{$j->{models}}) {
            $model = $j->{models}[0] // '';
        }
        return { status => 400, body => '{"message":"Invalid Horde model"}' }
            if $model =~ /Bad/i;
        my $id = 'job-ok';
        $id = 'job-censored' if $model =~ /Censored/i;
        $id = 'job-noworker' if $model =~ /NoWorker/i;
        if ($id eq 'job-ok') {
            my $n = 1;
            $n = 0 + $j->{params}{n}
                if $j && ref $j eq 'HASH' && ref $j->{params} eq 'HASH'
                && defined $j->{params}{n} && $j->{params}{n} =~ /^\d+$/;
            $id = "job-ok-$n";
        }
        return { status => 200, body => '{"id":"' . $id . '"}' };
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
        if ($model eq 'mock/censored') {
            return { status => 200, body => '{"data":[{"b64_json":"' . $png64 . '","censored":true}]}' };
        }
        if ($model eq 'mock/censorerr') {
            return { status => 400, body => '{"error":{"type":"content_filter","code":"content_filter","message":"AI Horde worker censored the generated image because this request was classified as SFW."}}' };
        }
        return { status => 200, body => '{"data":[{"b64_json":"' . $png64 . '"}]}' };
    }
    return { status => 404, body => 'unknown route', 'content-type' => 'text/plain' };
};

my ($spid, $sport) = start_server($handler, $S{log});
$S{spid} = $spid;

sub base { "http://127.0.0.1:$sport/v1" }
sub horde { "http://127.0.0.1:$sport/api" }

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

sub last_post {
    my $r = reqs();
    for my $item (reverse @$r) {
        return $item if defined $item->{head} && $item->{head} =~ m{^POST };
    }
    return undef;
}

sub last_post_json {
    my $item = last_post() or return undef;
    return eval { JSON::PP::decode_json($item->{body} // '') };
}

local %ENV = %ENV;
delete @ENV{qw(TUBULAR_CONFIG AI_HORDE_API_KEY)};
$ENV{TUBULAR_HOME} = tempdir(CLEANUP => 1);
$ENV{PATH} = tempdir(CLEANUP => 1);
$ENV{TUBULAR_HORDE_POLL_INTERVAL} = 0;
local $ENV{OMNIROUTE_API_KEY} = 'sk-cli-test';

subtest '--help' => sub {
    my ($o, $e, $code) = run($binimage, '--help');
    is($code, 0, 'exit 0');
    like($o, qr/Usage:/, 'usage shown');
    like($o, qr/OmniRoute/, 'mentions OmniRoute');
    like($o, qr/OMNIROUTE_API_KEY/, 'mentions the API key variable');
    like($o, qr/AI Horde/, 'mentions AI Horde');
    like($o, qr/AI_HORDE_API_KEY/, 'mentions the Horde key variable');
    like($o, qr/--horde-base-url/, 'documents --horde-base-url');
    like($o, qr/STDIN/, 'documents STDIN prompt');
    like($o, qr/--nsfw/, 'documents --nsfw');
    like($o, qr/--no-censor-nsfw/, 'documents --no-censor-nsfw');
    like($o, qr/classified as SFW/, 'documents SFW censor diagnostic');
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
        '--output', $out, '--horde-base-url', horde());
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
        $binimage, '--model', 'aihorde/Test', '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    like($o, qr/Generated image:/, 'success');
    my $body = last_post_json();
    is($body->{prompt}, "futuristic city at night\n", 'stdin prompt used verbatim');
};

subtest '--prompt wins over STDIN' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'prec.png');
    my ($o, $e, $code) = run_stdin("stdin prompt",
        $binimage, '--model', 'aihorde/Test', '--prompt', 'argument prompt',
        '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $body = last_post_json();
    is($body->{prompt}, 'argument prompt', '--prompt wins');
};

subtest 'prompt preserves unicode and newlines via STDIN' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'uni.png');
    my $want = "A caf\x{e9} at night\n\x{591c}\x{666f} scene";
    utf8::encode(my $bytes = $want);
    my ($o, $e, $code) = run_stdin($bytes,
        $binimage, '--model', 'aihorde/Test', '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $body = last_post_json();
    is($body->{prompt}, $want, 'unicode + multiline prompt preserved');
};

subtest 'request construction (model, n, size, auth)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'req.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--n', '2', '--size', '512x512',
        '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $item = last_post();
    my $j = eval { JSON::PP::decode_json($item->{body}) };
    is_deeply($j->{models}, ['Test'], 'Horde model prefix stripped');
    is($j->{params}{n}, 2, 'n in params');
    is($j->{params}{width}, 512, 'width in params');
    is($j->{params}{height}, 512, 'height in params');
    like($item->{head}, qr{^POST /api/v2/generate/async HTTP/1\.1}, 'Horde async endpoint');
    like($item->{head}, qr/apikey:\s*0000000000/i, 'anonymous Horde key');
    like($item->{head}, qr/Client-Agent:\s*tubular:0\.1:local/i, 'Client-Agent');
    unlike($item->{head}, qr/Authorization:\s*Bearer/i, 'no OmniRoute bearer');
    ok(JSON::PP::is_bool($j->{nsfw}), 'nsfw json bool');
    ok(!$j->{nsfw}, 'default nsfw false');
    ok(JSON::PP::is_bool($j->{censor_nsfw}), 'censor_nsfw json bool');
    ok($j->{censor_nsfw}, 'default censor_nsfw true');
    ok(JSON::PP::is_bool($j->{trusted_workers}), 'trusted_workers json bool');
    ok(!$j->{trusted_workers}, 'default trusted_workers false');
    ok(JSON::PP::is_bool($j->{replacement_filter}), 'replacement_filter json bool');
    ok($j->{replacement_filter}, 'default replacement_filter true');
};

subtest 'width/height normalize to size' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'wh.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x',
        '--width', '1024', '--height', '768', '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $j = last_post_json();
    is($j->{params}{width}, 1024, 'width from --width');
    is($j->{params}{height}, 768, 'height from --height');
};

subtest 'format overrides extension and sent as output_format' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'img');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--format', 'jpg',
        '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    ok(-e "$dir/img.jpg", 'jpg extension used');
    my $j = last_post_json();
    ok(!exists $j->{output_format}, 'Horde payload has no output_format');
};

subtest 'default output naming' => sub {
    my $wd = tempdir(CLEANUP => 1);
    my $old = Cwd::cwd();
    chdir $wd or die "chdir: $!";
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--horde-base-url', horde());
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
    like($e, qr/requested 3 images but the API returned 2/, 'warning on stderr');
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
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--horde-base-url', horde());
    is($code, 1, 'refused exits 1');
    like($e, qr/--force/, 'suggests --force');
    open my $rfh, '<', $out or die $!;
    local $/;
    is(<$rfh>, 'STALE', 'existing file untouched');
    close $rfh;

    ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out,
        '--force', '--horde-base-url', horde());
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

subtest 'missing OMNIROUTE_API_KEY exits 1 for OmniRoute models' => sub {
    local $ENV{OMNIROUTE_API_KEY};
    delete $ENV{OMNIROUTE_API_KEY};
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/b64', '--prompt', 'x', '--output', $out, '--base-url', base());
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
        '--json', '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--horde-base-url', horde());
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
        '--model', 'aihorde/Test', '--prompt', 'x', '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    ok(-e $out, 'file written through dispatcher');
};

subtest '--base-url is rejected for horde models' => sub {
    my (undef, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--base-url', base());
    is($code, 2, 'exit 2');
    like($e, qr/--base-url is for OmniRoute/, 'diagnostic');
};

subtest '--horde-base-url is rejected for non-horde models' => sub {
    my (undef, $e, $code) = run($binimage,
        '--model', 'mock/b64', '--prompt', 'x', '--horde-base-url', horde());
    is($code, 2, 'exit 2');
    like($e, qr/--horde-base-url is only valid/, 'diagnostic');
};

subtest '--nsfw classifies the Horde request as NSFW' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'nsfw.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--nsfw',
        '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $j = last_post_json();
    ok($j->{nsfw}, 'nsfw true');
    ok(!$j->{censor_nsfw}, 'censor_nsfw forced false');
};

subtest '--no-censor-nsfw keeps SFW classification without placeholder censoring' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'nocensor.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Test', '--prompt', 'x', '--no-censor-nsfw',
        '--output', $out, '--horde-base-url', horde());
    is($code, 0, 'exit 0');
    my $j = last_post_json();
    ok(!$j->{nsfw}, 'still SFW');
    ok(!$j->{censor_nsfw}, 'censor_nsfw false');
};

subtest 'non-horde models do not send Horde classification fields' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'openai.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/b64', '--prompt', 'x',
        '--output', $out, '--base-url', base());
    is($code, 0, 'exit 0');
    my $j = last_post_json();
    ok(!exists $j->{nsfw}, 'nsfw omitted');
    ok(!exists $j->{censor_nsfw}, 'censor_nsfw omitted');
};

subtest '--nsfw rejected for non-horde models' => sub {
    my (undef, $e, $code) = run($binimage,
        '--model', 'mock/b64', '--prompt', 'x', '--nsfw');
    is($code, 2, 'exit 2');
    like($e, qr/only valid for aihorde/, 'diagnostic');
};

subtest 'censored placeholder is not written as a successful image' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'blocked.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'mock/censored', '--prompt', 'x',
        '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    like($e, qr/AI Horde worker censored the generated image because this request was classified as SFW/, 'diagnostic');
    ok(!-e $out, 'placeholder not written');
};

subtest 'native Horde censored generation is not written' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'blocked.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/Censored', '--prompt', 'x',
        '--output', $out, '--horde-base-url', horde());
    is($code, 1, 'exit 1');
    like($e, qr/AI Horde worker censored the generated image because this request was classified as SFW/, 'diagnostic');
    ok(!-e $out, 'placeholder not written');
};

subtest 'native Horde worker-unavailable is explained' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'x.png');
    my ($o, $e, $code) = run($binimage,
        '--model', 'aihorde/NoWorker', '--prompt', 'x',
        '--output', $out, '--horde-base-url', horde());
    is($code, 1, 'exit 1');
    like($e, qr/no worker picked/i, 'queue hint');
};

subtest '--json reports censored OmniRoute errors' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $out = File::Spec->catfile($dir, 'cerr.png');
    my ($o, $e, $code) = run($binimage,
        '--json', '--model', 'mock/censorerr', '--prompt', 'x',
        '--output', $out, '--base-url', base());
    is($code, 1, 'exit 1');
    my $j = eval { JSON::PP::decode_json($o) };
    ok($j, 'valid JSON');
    is($j->{ok}, 0, 'ok false');
    ok($j->{censored}, 'censored flag');
    like($j->{error}, qr/classified as SFW/, 'message');
};

done_testing;
