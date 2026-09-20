use v5.44;
use warnings;
use utf8;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use IO::Socket::INET ();
use JSON::PP ();
use MIME::Base64 ();

use lib "$RealBin/../lib";
use tubular::Image;

my $root = dirname($RealBin);

my $png64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
my $png   = MIME::Base64::decode_base64($png64);

# Start a tiny HTTP/1.0 server that parses POST bodies and appends a JSON
# {head, body} record per request to $log. $S{port} is set before forking so
# the handler closure (which runs in the child) can build URLs.
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
            if ($clen > 0) {
                read $conn, $body, $clen;
            }
            my $res = $handler->($head, $body);
            $res = { status => 200, body => $res } if !ref $res;
            $res->{body} //= '';
            $res->{'content-type'} //= 'application/json';
            if (defined $log) {
                open my $lf, '>>:raw', $log or next;
                print {$lf} JSON::PP::encode_json({ head => $head, body => $body }), "\n";
                close $lf;
            }
            my $ct = $res->{'content-type'};
            print {$conn} 'HTTP/1.0 ' . $res->{status} . " X\r\n"
                . "Content-Type: $ct\r\n"
                . 'Content-Length: ' . length($res->{body}) . "\r\n"
                . "Connection: close\r\n\r\n" . $res->{body};
            close $conn;
        }
        exit 0;
    }
    $S{spid} = $pid;
    return ($pid, $S{port});
}

sub cleanup { kill 'TERM', $S{spid} if $S{spid} }
END { cleanup() }

$S{log} = File::Spec->catfile(tempdir(CLEANUP => 1), 'requests.log');

my $handler = sub ($head, $body) {
    my ($line) = split /\r?\n/, $head;
    if ($line =~ m{^GET /([^\s?]+) HTTP/1\.1}) {
        my $path = $1;
        return { status => 200, body => $png, 'content-type' => 'image/png' }
            if $path eq 'raw.png';
        return { status => 200, body => $png, 'content-type' => 'image/webp' }
            if $path eq 'art.webp';
        return { status => 500, body => 'nope', 'content-type' => 'text/plain' }
            if $path eq 'broken.png';
        return { status => 404, body => 'gone', 'content-type' => 'text/plain' };
    }
    if ($line =~ m{^POST /v1/images/generations HTTP/1\.1}) {
        my $j = eval { JSON::PP::decode_json($body) };
        my $model = $j && ref $j eq 'HASH' && defined $j->{model} ? $j->{model} : '';
        if ($model eq 'mock/two') {
            return { status => 200, body => '{"data":[{"b64_json":"' . $png64
                . '"},{"b64_json":"' . $png64 . '"}]}' };
        }
        return { status => 200, body => '{"data":[{"b64_json":"'
            . 'data:image/png;base64,' . $png64 . '"}]}' }
            if $model eq 'mock/b64uri';
        return { status => 200, body => '{"data":[{"url":"' . "http://127.0.0.1:$S{port}/raw.png"
            . '"}]}' }
            if $model eq 'mock/url';
        return { status => 200, body => '{"data":[{"url":"' . "http://127.0.0.1:$S{port}/art.webp"
            . '"}]}' }
            if $model eq 'mock/urlwebp';
        return { status => 200, body => '{"data":[{"url":"' . "http://127.0.0.1:$S{port}/broken.png"
            . '"}]}' }
            if $model eq 'mock/urlbroken';
        return { status => 200, body => '{"data":[{"url":"' . "http://127.0.0.1:$S{port}/gone.png"
            . '"}]}' }
            if $model eq 'mock/urlgone';
        return { status => 200, body => '{"data":[]}' }
            if $model eq 'mock/emptydata';
        return { status => 200, body => '{"created":0}' }
            if $model eq 'mock/nodata';
        return { status => 200, body => '{"data":[],"wait_time":45,"queue_position":3}' }
            if $model eq 'mock/queued';
        return { status => 503, body => '{"error":{"type":"service_unavailable","message":"No Horde workers can currently fulfill this request","code":"service_unavailable"}}' }
            if $model eq 'mock/err503';
        return { status => 200, body => '{"created":1,"wait_time":12,"queue_position":1,"data":[{"b64_json":"' . $png64 . '"}]}' }
            if $model eq 'mock/successqueue';
        return { status => 200, body => '{"data":[{"b64_json":"!!!"}]}' }
            if $model eq 'mock/badb64';
        return { status => 200, body => 'not json at all' }
            if $model eq 'mock/malformed';
        return { status => 400, body => '{"error":{"message":"Invalid image model: nope. Use format: provider/model"}}' }
            if $model eq 'mock/apierr';
        return { status => 500, body => 'oops', 'content-type' => 'text/plain' }
            if $model eq 'mock/err500';
        if ($model eq 'mock/slow') {
            select undef, undef, undef, 3;
            return { status => 200, body => '{"data":[]}' };
        }
        return { status => 200, body => '{"data":[{"b64_json":"' . $png64
            . '","revised_prompt":"refined"}]}' };
    }
    return { status => 404, body => 'unknown route', 'content-type' => 'text/plain' };
};

my ($spid, $sport) = start_server($handler, $S{log});

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

sub last_req_body {
    my $r = reqs();
    return undef unless @$r;
    return $r->[-1]{body};
}

local $ENV{OMNIROUTE_API_KEY} = 'sk-module-test';

subtest 'generates a base64 image' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'a red car');
    ok($res->{ok}, 'ok');
    is(scalar @{ $res->{images} }, 1, 'one image');
    my $im = $res->{images}[0];
    is($im->{kind}, 'b64_json', 'b64 source');
    is($im->{ext}, 'png', 'png extension');
    is(${ $im->{bytes} }, $png, 'decoded bytes equal fixture');
};

subtest 'data-URI base64 is decoded' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64uri', prompt => 'a red car');
    ok($res->{ok}, 'ok');
    is(scalar @{ $res->{images} }, 1, 'one image');
    is(${ $res->{images}[0]{bytes} }, $png, 'bytes match');
    is($res->{images}[0]{ext}, 'png', 'png from media type');
};

subtest 'revised_prompt is carried through' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'a red car');
    is($res->{images}[0]{revised_prompt}, 'refined', 'revised prompt kept');
};

subtest 'multiple images (n=2)' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/two', prompt => 'x', n => 2);
    ok($res->{ok}, 'ok');
    is(scalar @{ $res->{images} }, 2, 'two images');
    is($res->{requested_n}, 2, 'requested n recorded');
    cmp_ok(length ${ $res->{images}[1]{bytes} }, '>', 0, 'second has bytes');
};

subtest 'URL image is downloaded' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/url', prompt => 'x');
    ok($res->{ok}, 'ok');
    my $im = $res->{images}[0];
    is($im->{kind}, 'url', 'url source');
    is(${ $im->{bytes} }, $png, 'downloaded bytes');
    is($im->{ext}, 'png', 'png from content-type');
    is($im->{content_type}, 'image/png', 'content type kept');
};

subtest 'URL extension falls back to content-type' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/urlwebp', prompt => 'x');
    ok($res->{ok}, 'ok');
    is($res->{images}[0]{ext}, 'webp', 'webp from content type');
};

subtest 'failed URL download fails the request' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/urlgone', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/HTTP 404/, 'reports status code');
};

subtest 'non-2xx URL download fails the request' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/urlbroken', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/HTTP 500/, 'reports status code');
};

subtest 'empty/missing data array rejected' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/emptydata', prompt => 'x');
    ok(!$res->{ok}, 'empty data rejected');
    like($res->{error}, qr/no image data/, 'clear error');
    $res = $img->generate(model => 'mock/nodata', prompt => 'x');
    ok(!$res->{ok}, 'missing data rejected');
    like($res->{error}, qr/no image data/, 'clear error');
};

subtest 'invalid base64 rejected' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/badb64', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/invalid base64/, 'clear error');
};

subtest 'malformed JSON rejected' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/malformed', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/malformed JSON/, 'clear error');
};

subtest 'API error message surfaced' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/apierr', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/HTTP 400/, 'has status');
    like($res->{error}, qr/Invalid image model: nope/, 'has API message');
    unlike($res->{error}, qr/sk-module-test/, 'API key never leaked');
};

subtest 'non-JSON API error' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/err500', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/HTTP 500/, 'status reported');
};

subtest 'queued response surfaces wait time and queue position' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/queued', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    ok($res->{queued}, 'flagged as queued');
    is($res->{wait_time}, 45, 'wait time surfaced');
    is($res->{queue_position}, 3, 'queue position surfaced');
    like($res->{error}, qr/queued/, 'error explains the queue');
    like($res->{error}, qr/~45 seconds/, 'error mentions the wait');
};

subtest 'worker-unavailable error is explained as a queue wait' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/err503', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/HTTP 503/, 'has status');
    like($res->{error}, qr/service_unavailable/, 'error code surfaced');
    like($res->{error}, qr/run in a queue/, 'hint explains the queue');
    is($res->{error_code}, 'service_unavailable', 'structured code');
    is($res->{error_type}, 'service_unavailable', 'structured type');
};

subtest 'queue info rides along with successful images' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/successqueue', prompt => 'x');
    ok($res->{ok}, 'ok');
    is($res->{wait_time}, 12, 'wait time kept');
    is($res->{queue_position}, 1, 'queue position kept');
    is(scalar @{ $res->{images} }, 1, 'image decoded');
};

subtest 'timeout surfaces cleanly' => sub {
    my $img = tubular::Image->new(base_url => base(), timeout => 1);
    my $res = $img->generate(model => 'mock/slow', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/cannot reach OmniRoute/i, 'connection error reported');
    like($res->{error}, qr/timed out/i, 'timeout mentioned');
};

subtest 'missing API key' => sub {
    local $ENV{OMNIROUTE_API_KEY};
    delete $ENV{OMNIROUTE_API_KEY};
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/OMNIROUTE_API_KEY/, 'clear error');
};

subtest 'validation: required fields' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(prompt => 'x');
    ok(!$res->{ok}, 'missing model');
    like($res->{error}, qr/model is required/, 'error');
    $res = $img->generate(model => 'mock/b64');
    ok(!$res->{ok}, 'missing prompt');
    like($res->{error}, qr/prompt is required/, 'error');
    $res = $img->generate(model => 'mock/b64', prompt => '');
    ok(!$res->{ok}, 'empty prompt');
    like($res->{error}, qr/prompt must not be empty/, 'error');
};

subtest 'request body construction' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(
        model           => 'mock/b64',
        prompt          => "a red car\nwith a 'quote' and é",
        n               => 2,
        size            => '1024x1024',
        quality         => 'high',
        seed            => 42,
        output_format   => 'png',
        negative_prompt => 'blurry',
    );
    ok($res->{ok}, 'ok');
    my $body = JSON::PP::decode_json(last_req_body());
    is($body->{model}, 'mock/b64', 'model in request');
    is($body->{prompt}, "a red car\nwith a 'quote' and é", 'prompt preserved');
    is($body->{n}, 2, 'n in request');
    is($body->{size}, '1024x1024', 'size in request');
    is($body->{quality}, 'high', 'quality in request');
    is($body->{seed}, 42, 'seed in request');
    is($body->{output_format}, 'png', 'output_format in request');
    is($body->{negative_prompt}, 'blurry', 'negative_prompt in request');

    my $reqs = reqs();
    my $last_head = $reqs->[-1]{head};
    like($last_head, qr{^POST /v1/images/generations HTTP/1\.1}, 'endpoint hit');
    like($last_head, qr/Authorization: Bearer sk-module-test/i, 'auth header uses env key');
};

subtest 'extra fields are omitted when not supplied' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'x');
    ok($res->{ok}, 'ok');
    my $body = $res->{ok} && JSON::PP::decode_json(last_req_body());
    for my $absent (qw(size quality seed output_format negative_prompt n)) {
        ok(!exists $body->{$absent}, "$absent not sent when absent") if $body;
    }
};

subtest 'unexpected fields are not sent' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'x', bogus => 1);
    ok($res->{ok}, 'ok');
    my $body = JSON::PP::decode_json(last_req_body());
    ok(!exists $body->{bogus}, 'unexpected field dropped');
};

subtest 'base_url trailing slash normalized' => sub {
    my $img = tubular::Image->new(base_url => "http://127.0.0.1:$sport/v1/");
    my $res = $img->generate(model => 'mock/b64', prompt => 'x');
    ok($res->{ok}, 'ok with trailing slash');
    my $reqs = reqs();
    like($reqs->[-1]{head}, qr{^POST /v1/images/generations HTTP/1\.1}, 'endpoint normalized');
};

subtest 'n must be a positive integer' => sub {
    my $img = tubular::Image->new(base_url => base());
    my $res = $img->generate(model => 'mock/b64', prompt => 'x', n => 0);
    ok(!$res->{ok}, 'zero rejected');
    like($res->{error}, qr/positive integer/, 'error');
    $res = $img->generate(model => 'mock/b64', prompt => 'x', n => 'two');
    ok(!$res->{ok}, 'non numeric rejected');
};

done_testing;