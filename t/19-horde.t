use v5.44;
use warnings;
use utf8;
use Test::More;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($RealBin);
use IO::Socket::INET ();
use JSON::PP ();
use MIME::Base64 ();

use lib "$RealBin/../lib";
use tubular::Adapter::Horde;
use tubular::Image;

my $png64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
my $png   = MIME::Base64::decode_base64($png64);

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
    $S{spid} = $pid;
    return ($pid, $S{port});
}

sub cleanup { kill 'TERM', $S{spid} if $S{spid} }
END { cleanup() }

$S{log} = File::Spec->catfile(tempdir(CLEANUP => 1), 'requests.log');
my %check_count;

my $handler = sub ($head, $body) {
    my ($line) = split /\r?\n/, $head;
    if ($line =~ m{^GET /raw\.png HTTP/1\.[01]}) {
        return { status => 200, body => $png, 'content-type' => 'image/png' };
    }
    if ($line =~ m{^(GET|DELETE) /(?:api/)?v2/generate/(check|status)/([^\s?]+) HTTP/1\.[01]}) {
        my ($method, $kind, $id) = ($1, $2, $3);
        if ($method eq 'DELETE') {
            return { status => 200, body => '{}' };
        }
        if ($kind eq 'check') {
            $check_count{$id}++;
            if ($id eq 'job-noworker') {
                return { status => 200, body => '{"done":false,"is_possible":false}' };
            }
            if ($id eq 'job-hang') {
                return { status => 200, body => '{"done":false,"is_possible":true,"wait_time":99,"queue_position":9}' };
            }
            if ($id eq 'job-poll') {
                if ($check_count{$id} < 2) {
                    return { status => 200, body => '{"done":false,"is_possible":true,"wait_time":5,"queue_position":3}' };
                }
                return { status => 200, body => '{"done":true,"wait_time":1,"queue_position":0,"is_possible":true}' };
            }
            return { status => 200, body => '{"done":true,"wait_time":12,"queue_position":1,"is_possible":true}' };
        }
        if ($id eq 'job-censored') {
            return { status => 200, body => '{"generations":[{"img":"http://127.0.0.1:'
                . $S{port} . '/raw.png","censored":true}]}' };
        }
        if ($id eq 'job-b64') {
            return { status => 200, body => '{"generations":[{"img":"' . $png64 . '"}]}' };
        }
        return { status => 200, body => '{"wait_time":12,"queue_position":1,"generations":[{"img":"http://127.0.0.1:'
            . $S{port} . '/raw.png"}]}' };
    }
    if ($line =~ m{^POST /(?:api/)?v2/generate/async HTTP/1\.[01]}) {
        my $j = eval { JSON::PP::decode_json($body) };
        my $model = '';
        if ($j && ref $j eq 'HASH' && ref $j->{models} eq 'ARRAY' && @{$j->{models}}) {
            $model = $j->{models}[0] // '';
        }
        return { status => 400, body => '{"message":"unknown model"}' } if $model =~ /Bad/i;
        my $id = 'job-ok';
        $id = 'job-censored' if $model =~ /Censored/i;
        $id = 'job-noworker' if $model =~ /NoWorker/i;
        $id = 'job-hang'     if $model =~ /Hang/i;
        $id = 'job-poll'     if $model =~ /Poll/i;
        $id = 'job-b64'      if $model =~ /B64/i;
        return { status => 200, body => '{"id":"' . $id . '"}' };
    }
    return { status => 404, body => 'unknown route', 'content-type' => 'text/plain' };
};

my ($spid, $sport) = start_server($handler, $S{log});

sub horde_base { "http://127.0.0.1:$sport/api" }

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
delete @ENV{qw(AI_HORDE_API_KEY OMNIROUTE_API_KEY TUBULAR_DEBUG_IMAGE)};

subtest 'is_horde_model and strip_model_prefix' => sub {
    ok(tubular::Adapter::Horde::is_horde_model('aihorde/SDXL 1.0'), 'aihorde prefix');
    ok(tubular::Adapter::Horde::is_horde_model('horde/Flux'), 'horde prefix');
    ok(tubular::Adapter::Horde::is_horde_model('AIHORDE/x'), 'case insensitive');
    ok(!tubular::Adapter::Horde::is_horde_model('mock/b64'), 'other provider');
    ok(!tubular::Adapter::Horde::is_horde_model(undef), 'undef');
    is(tubular::Adapter::Horde::strip_model_prefix('aihorde/SDXL 1.0'), 'SDXL 1.0', 'strip aihorde');
    is(tubular::Adapter::Horde::strip_model_prefix('horde/Flux'), 'Flux', 'strip horde');
    is(tubular::Adapter::Horde::strip_model_prefix('aihorde/'), undef, 'empty name');
};

subtest 'map_generate_request sends explicit SFW defaults' => sub {
    my $mapped = tubular::Adapter::Horde::map_generate_request({
        model  => 'aihorde/SDXL 1.0',
        prompt => 'a red car',
    });
    ok($mapped->{ok}, 'ok');
    my $p = $mapped->{payload};
    is_deeply($p->{models}, ['SDXL 1.0'], 'model prefix stripped');
    is($p->{prompt}, 'a red car', 'prompt');
    ok(JSON::PP::is_bool($p->{nsfw}), 'nsfw json bool');
    ok(!$p->{nsfw}, 'nsfw false');
    ok(JSON::PP::is_bool($p->{censor_nsfw}), 'censor_nsfw json bool');
    ok($p->{censor_nsfw}, 'censor_nsfw true');
    ok(!$p->{trusted_workers}, 'trusted_workers false');
    ok($p->{replacement_filter}, 'replacement_filter true');
    is($p->{params}{n}, 1, 'n default 1');
    is($p->{params}{width}, 1024, 'auto width');
    is($p->{params}{height}, 1024, 'auto height');
};

subtest 'nsfw true forces censor_nsfw false' => sub {
    my $mapped = tubular::Adapter::Horde::map_generate_request({
        model       => 'horde/Flux',
        prompt      => 'x',
        nsfw        => 1,
        censor_nsfw => 1,
    });
    ok($mapped->{ok}, 'ok');
    ok($mapped->{payload}{nsfw}, 'nsfw true');
    ok(!$mapped->{payload}{censor_nsfw}, 'censor forced false');
};

subtest 'negative prompt, seed string, size snap, n cap' => sub {
    my $mapped = tubular::Adapter::Horde::map_generate_request({
        model           => 'aihorde/Test',
        prompt          => 'lake',
        negative_prompt => 'blurry',
        seed            => 42,
        size            => '100x200',
        n               => 99,
    });
    ok($mapped->{ok}, 'ok');
    is($mapped->{payload}{prompt}, 'lake ### blurry', 'negative prompt appended');
    is($mapped->{payload}{params}{seed}, '42', 'seed is a string');
    is($mapped->{payload}{params}{width}, 128, 'width snapped to 64');
    is($mapped->{payload}{params}{height}, 192, 'height snapped to 64');
    is($mapped->{payload}{params}{n}, 20, 'n capped at 20');
};

subtest 'map_generate_request validation' => sub {
    my $mapped = tubular::Adapter::Horde::map_generate_request({ prompt => 'x' });
    ok(!$mapped->{ok}, 'missing model');
    $mapped = tubular::Adapter::Horde::map_generate_request({
        model => 'aihorde/x', prompt => 'x', nsfw => 'yes',
    });
    ok(!$mapped->{ok}, 'bad nsfw');
    like($mapped->{error}, qr/nsfw must be a boolean/, 'nsfw error');
    $mapped = tubular::Adapter::Horde::map_generate_request({
        model => 'aihorde/x', prompt => 'x', size => 'banana',
    });
    ok(!$mapped->{ok}, 'bad size');
};

sub adapter (%extra) {
    return tubular::Adapter::Horde->new(
        base_url      => horde_base(),
        timeout       => 5,
        poll_interval => 0,
        %extra,
    );
}

subtest 'generate downloads a URL image and records queue info' => sub {
    my $res = adapter()->generate(model => 'aihorde/Test', prompt => 'a lake');
    ok($res->{ok}, 'ok') or diag($res->{error});
    is(scalar @{ $res->{images} }, 1, 'one image');
    is(${ $res->{images}[0]{bytes} }, $png, 'downloaded bytes');
    is($res->{images}[0]{kind}, 'url', 'url source');
    is($res->{wait_time}, 12, 'wait time');
    is($res->{queue_position}, 1, 'queue position');
    my $item = last_post();
    like($item->{head}, qr{^POST /api/v2/generate/async HTTP/1\.1}, 'submit endpoint');
    like($item->{head}, qr/apikey:\s*0000000000/i, 'anonymous key');
    like($item->{head}, qr/Client-Agent:\s*tubular:0\.1:local/i, 'Client-Agent');
    my $body = last_post_json();
    is_deeply($body->{models}, ['Test'], 'stripped model');
    ok(!$body->{nsfw}, 'explicit SFW');
    ok($body->{censor_nsfw}, 'explicit censor_nsfw');
};

subtest 'horde/ prefix and base64 payload' => sub {
    my $res = adapter()->generate(model => 'horde/B64', prompt => 'x');
    ok($res->{ok}, 'ok') or diag($res->{error});
    is($res->{images}[0]{kind}, 'b64_json', 'b64 source');
    is(${ $res->{images}[0]{bytes} }, $png, 'decoded bytes');
};

subtest 'censored generation is a failure, not a placeholder' => sub {
    my $res = adapter()->generate(model => 'aihorde/Censored', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    ok($res->{censored}, 'censored flag');
    is($res->{error_code}, 'content_filter', 'error code');
    is($res->{error}, tubular::Adapter::Horde::censored_message(), 'diagnostic');
};

subtest 'no worker is a queue wait' => sub {
    my $res = adapter()->generate(model => 'aihorde/NoWorker', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    is($res->{error_code}, 'service_unavailable', 'code');
    like($res->{error}, qr/no worker picked/i, 'hint');
};

subtest 'polls until done' => sub {
    my $res = adapter()->generate(model => 'aihorde/Poll', prompt => 'x');
    ok($res->{ok}, 'ok after extra check') or diag($res->{error});
    my $checks = grep {
        defined $_->{head} && $_->{head} =~ m{GET /(?:api/)?v2/generate/check/job-poll}
    } @{ reqs() };
    cmp_ok($checks, '>=', 2, 'polled at least twice');
};

subtest 'AI_HORDE_API_KEY is sent and never logged' => sub {
    local $ENV{AI_HORDE_API_KEY} = 'secret-horde-key';
    local $ENV{TUBULAR_DEBUG_IMAGE} = 1;
    my $warn = '';
    local $SIG{__WARN__} = sub { $warn .= $_[0] };
    my $res = adapter()->generate(model => 'aihorde/Test', prompt => 'x');
    ok($res->{ok}, 'ok') or diag($res->{error});
    my $item = last_post();
    like($item->{head}, qr/apikey:\s*secret-horde-key/i, 'real key in header');
    unlike($warn, qr/secret-horde-key/, 'debug log does not contain the key');
    like($warn, qr/tubular::Adapter::Horde outbound:/, 'debug prefix');
    like($warn, qr/"nsfw":false/, 'debug includes nsfw');
    like($warn, qr/"censor_nsfw":true/, 'debug includes censor_nsfw');
};

subtest 'tubular::Image dispatches horde models without OMNIROUTE_API_KEY' => sub {
    local $ENV{OMNIROUTE_API_KEY};
    delete $ENV{OMNIROUTE_API_KEY};
    my $img = tubular::Image->new(
        base_url            => "http://127.0.0.1:$sport/v1",
        horde_base_url      => horde_base(),
        timeout             => 5,
        horde_poll_interval => 0,
    );
    my $res = $img->generate(model => 'aihorde/Test', prompt => 'from image');
    ok($res->{ok}, 'ok') or diag($res->{error});
    my $body = last_post_json();
    is($body->{prompt}, 'from image', 'payload from Image.pm');
    like(last_post()->{head}, qr{POST /api/v2/generate/async}, 'Horde path, not OmniRoute');
};

subtest 'non-horde models are rejected by the adapter' => sub {
    my $res = adapter()->generate(model => 'mock/b64', prompt => 'x');
    ok(!$res->{ok}, 'not ok');
    like($res->{error}, qr/not an aihorde/, 'clear error');
};

done_testing;
