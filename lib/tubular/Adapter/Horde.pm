package tubular::Adapter::Horde;

use v5.44;
use warnings;

use HTTP::Tiny ();
use JSON::PP ();
use MIME::Base64 ();
use Scalar::Util qw(looks_like_number);
use Time::HiRes qw(time);

our $VERSION = '0.1';

my $DEFAULT_BASE_URL    = 'https://aihorde.net/api';
my $ANONYMOUS_KEY       = '0000000000';
my $CLIENT_AGENT        = 'tubular:0.1:local';
my $DEFAULT_TIMEOUT     = 300;
my $DEFAULT_MAX_BYTES   = 25_000_000;
my $DEFAULT_POLL        = 1;
my $DEFAULT_WIDTH       = 1024;
my $DEFAULT_HEIGHT      = 1024;
my $DEFAULT_STEPS       = 20;
my $MAX_N               = 20;
my $MIN_DIM             = 64;
my $MAX_DIM             = 3072;
my $DIM_STEP            = 64;
my $HORDE_SFW_CENSORED_MSG
    = 'AI Horde worker censored the generated image because this request was classified as SFW.';

my %MIME_EXT = (
    'image/png'  => 'png',
    'image/jpeg' => 'jpg',
    'image/jpg'  => 'jpg',
    'image/webp' => 'webp',
    'image/gif'  => 'gif',
    'image/bmp'  => 'bmp',
    'image/avif' => 'avif',
);

sub censored_message { return $HORDE_SFW_CENSORED_MSG }
sub anonymous_key    { return $ANONYMOUS_KEY }
sub default_base_url { return $DEFAULT_BASE_URL }

sub is_horde_model ($model) {
    return defined $model && !ref $model && $model =~ m{\A(?:aihorde|horde)/}i;
}

sub strip_model_prefix ($model) {
    return undef unless defined $model && !ref $model;
    my $name = $model;
    $name =~ s{\A\s+}{};
    $name =~ s{\s+\z}{};
    $name =~ s{\A(?:aihorde|horde)/}{}i;
    return length $name ? $name : undef;
}

sub new ($class, %args) {
    my $poll = $args{poll_interval};
    if (!defined $poll && defined $ENV{TUBULAR_HORDE_POLL_INTERVAL}
        && $ENV{TUBULAR_HORDE_POLL_INTERVAL} =~ /\A\d+(?:\.\d+)?\z/) {
        $poll = 0 + $ENV{TUBULAR_HORDE_POLL_INTERVAL};
    }
    my $self = bless {
        base_url      => defined $args{base_url} && length $args{base_url}
            ? $args{base_url} : $DEFAULT_BASE_URL,
        timeout       => defined $args{timeout} ? $args{timeout} : $DEFAULT_TIMEOUT,
        max_bytes     => defined $args{max_bytes} ? $args{max_bytes} : $DEFAULT_MAX_BYTES,
        api_key       => $args{api_key},
        poll_interval => defined $poll ? $poll : $DEFAULT_POLL,
        sleep         => $args{sleep},
    }, $class;
    $self->{base_url} =~ s{/+\z}{};
    return $self;
}

# AI_HORDE_API_KEY if set; otherwise Horde's documented anonymous key.
# The anonymous key is not a secret. Never log a real key.
sub api_key ($self) {
    if (defined $self->{api_key} && length $self->{api_key}) {
        return $self->{api_key};
    }
    if (defined $ENV{AI_HORDE_API_KEY} && length $ENV{AI_HORDE_API_KEY}) {
        return $ENV{AI_HORDE_API_KEY};
    }
    return $ANONYMOUS_KEY;
}

sub _as_bool ($v) {
    return JSON::PP::true  if JSON::PP::is_bool($v) && $v;
    return JSON::PP::false if JSON::PP::is_bool($v);
    if (!ref $v && looks_like_number($v) && ("$v" eq '0' || "$v" eq '1')) {
        return $v ? JSON::PP::true : JSON::PP::false;
    }
    return undef;
}

sub _snap_dim ($value) {
    my $snapped = int(($value + $DIM_STEP / 2) / $DIM_STEP) * $DIM_STEP;
    $snapped = $MIN_DIM if $snapped < $MIN_DIM;
    $snapped = $MAX_DIM if $snapped > $MAX_DIM;
    return $snapped;
}

sub parse_size ($size) {
    if (!defined $size || $size eq '' || $size eq 'auto') {
        return { ok => 1, width => $DEFAULT_WIDTH, height => $DEFAULT_HEIGHT };
    }
    if ($size !~ /^\s*(\d+)\s*x\s*(\d+)\s*$/i) {
        return { ok => 0, error => "size must look like WIDTHxHEIGHT, got $size" };
    }
    return {
        ok     => 1,
        width  => _snap_dim(0 + $1),
        height => _snap_dim(0 + $2),
    };
}

# Pure mapping from a tubular image request onto Horde POST /v2/generate/async.
# SFW defaults are explicit: nsfw=false, censor_nsfw=true, trusted_workers=false,
# replacement_filter=true. nsfw=true forces censor_nsfw=false (Horde constraint).
sub map_generate_request ($req) {
    my $prompt = $req->{prompt};
    if (!defined $prompt || ref $prompt || $prompt eq '') {
        return { ok => 0, error => 'prompt is required' };
    }
    my $model = strip_model_prefix($req->{model});
    if (!defined $model) {
        return { ok => 0, error => 'model is required' };
    }

    my $n = 1;
    if (defined $req->{n}) {
        if (!looks_like_number($req->{n}) || "$req->{n}" !~ /^\d+$/ || $req->{n} < 1) {
            return { ok => 0, error => 'n must be a positive integer' };
        }
        $n = 0 + $req->{n};
        $n = $MAX_N if $n > $MAX_N;
    }

    my $size = parse_size($req->{size});
    return $size unless $size->{ok};

    my $nsfw = JSON::PP::false;
    if (exists $req->{nsfw} && defined $req->{nsfw}) {
        my $b = _as_bool($req->{nsfw});
        return { ok => 0, error => 'nsfw must be a boolean' } unless defined $b;
        $nsfw = $b;
    }
    my $censor = JSON::PP::true;
    if (exists $req->{censor_nsfw} && defined $req->{censor_nsfw}) {
        my $b = _as_bool($req->{censor_nsfw});
        return { ok => 0, error => 'censor_nsfw must be a boolean' } unless defined $b;
        $censor = $b;
    }
    $censor = JSON::PP::false if $nsfw;

    my $trusted = JSON::PP::false;
    if (exists $req->{trusted_workers} && defined $req->{trusted_workers}) {
        my $b = _as_bool($req->{trusted_workers});
        return { ok => 0, error => 'trusted_workers must be a boolean' } unless defined $b;
        $trusted = $b;
    }
    my $replacement = JSON::PP::true;
    if (exists $req->{replacement_filter} && defined $req->{replacement_filter}) {
        my $b = _as_bool($req->{replacement_filter});
        return { ok => 0, error => 'replacement_filter must be a boolean' } unless defined $b;
        $replacement = $b;
    }

    my $full_prompt = $prompt;
    if (defined $req->{negative_prompt} && length $req->{negative_prompt}) {
        $full_prompt .= ' ### ' . $req->{negative_prompt};
    }

    my %params = (
        n      => $n,
        width  => $size->{width},
        height => $size->{height},
        steps  => $DEFAULT_STEPS,
    );
    if (defined $req->{seed}) {
        if (!looks_like_number($req->{seed}) || "$req->{seed}" !~ /^-?\d+$/) {
            return { ok => 0, error => 'seed must be an integer' };
        }
        $params{seed} = "$req->{seed}";
    }

    my $payload = {
        prompt             => $full_prompt,
        models             => [$model],
        nsfw               => $nsfw,
        censor_nsfw        => $censor,
        trusted_workers    => $trusted,
        replacement_filter => $replacement,
        r2                 => JSON::PP::true,
        shared             => JSON::PP::false,
        validated_backends => JSON::PP::true,
        slow_workers       => JSON::PP::true,
        allow_downgrade    => JSON::PP::true,
        params             => \%params,
    };
    return { ok => 1, payload => $payload };
}

sub sanitize_outbound ($payload) {
    my %out = %$payload;
    $out{source_image} = '[omitted]' if exists $out{source_image};
    $out{source_mask}  = '[omitted]' if exists $out{source_mask};
    return \%out;
}

sub generate ($self, %req) {
    my $model  = $req{model};
    my $prompt = $req{prompt};

    if (!defined $model || ref $model || $model eq '') {
        return { ok => 0, error => 'model is required' };
    }
    if (!is_horde_model($model)) {
        return { ok => 0, error => 'model is not an aihorde/* or horde/* model' };
    }
    if (!defined $prompt || ref $prompt) {
        return { ok => 0, error => 'prompt is required' };
    }
    if ($prompt eq '') {
        return { ok => 0, error => 'prompt must not be empty' };
    }

    my $mapped = map_generate_request(\%req);
    if (!$mapped->{ok}) {
        return { ok => 0, error => $mapped->{error}, model => $model };
    }
    my $payload = $mapped->{payload};
    my $base    = $self->{base_url};
    my $submit_url = "$base/v2/generate/async";
    my $json = JSON::PP->new->utf8->canonical->encode($payload);
    if ($ENV{TUBULAR_DEBUG_IMAGE}) {
        warn 'tubular::Adapter::Horde outbound: '
            . JSON::PP->new->utf8->canonical->encode(sanitize_outbound($payload)) . "\n";
    }

    my $result = {
        ok          => 0,
        model       => $model,
        base_url    => $base,
        endpoint    => $submit_url,
        requested_n => $payload->{params}{n},
    };

    my $ua = $self->_ua;
    my $headers = $self->_headers;
    my $resp = eval {
        $ua->post($submit_url, {
            headers => $headers,
            content => $json,
        });
    };
    if ($@) {
        $result->{error} = "cannot reach AI Horde at $submit_url: $@";
        return $result;
    }
    if (!ref $resp || $resp->{status} == 599) {
        my $msg = (ref $resp && defined $resp->{content}) ? $resp->{content} : 'request failed';
        $result->{error} = "cannot reach AI Horde at $submit_url: $msg";
        return $result;
    }
    $result->{http_status} = $resp->{status};
    if ($resp->{status} !~ /^2\d\d$/) {
        $result->{error} = 'AI Horde submit failed (HTTP ' . $resp->{status} . '): '
            . _horde_message($resp->{content}, $resp->{reason} // 'request failed');
        return $result;
    }
    my $decoded = eval { JSON::PP::decode_json($resp->{content} // '') };
    if ($@ || ref $decoded ne 'HASH' || !defined $decoded->{id} || !length "$decoded->{id}") {
        $result->{error} = 'AI Horde submit did not return a job id';
        return $result;
    }
    my $job_id = "$decoded->{id}";
    $result->{job_id} = $job_id;

    my $deadline = time() + ($self->{timeout} || $DEFAULT_TIMEOUT);
    my $completed = 0;
    my $wait_time;
    my $queue_position;
    eval {
        while (1) {
            if (time() >= $deadline) {
                die "AI Horde image generation timed out\n";
            }
            $self->_sleep($self->{poll_interval});
            my $check = $self->_get("$base/v2/generate/check/$job_id", $headers);
            if (!$check->{ok}) {
                die "$check->{error}\n";
            }
            my $obj = $check->{json};
            if ($obj->{faulted}) {
                die "AI Horde marked the job as faulted\n";
            }
            if (defined $obj->{is_possible} && !$obj->{is_possible}) {
                die "No Horde workers can currently fulfill this request "
                    . "(aihorde jobs run in a queue; no worker picked this one up - retry in a bit)\n";
            }
            $wait_time = $obj->{wait_time} if looks_like_number($obj->{wait_time});
            $queue_position = $obj->{queue_position}
                if looks_like_number($obj->{queue_position});
            next unless $obj->{done};

            my $status = $self->_get("$base/v2/generate/status/$job_id", $headers);
            if (!$status->{ok}) {
                die "$status->{error}\n";
            }
            my $generations = $status->{json}{generations};
            if (ref $generations ne 'ARRAY' || !@$generations) {
                die "AI Horde status contained no generations\n";
            }
            $wait_time = $status->{json}{wait_time}
                if looks_like_number($status->{json}{wait_time});
            $queue_position = $status->{json}{queue_position}
                if looks_like_number($status->{json}{queue_position});

            my @images;
            my $idx = 0;
            for my $item (@$generations) {
                next unless ref $item eq 'HASH';
                if ($item->{censored}) {
                    $completed = 1;
                    $result->{censored}   = 1;
                    $result->{error_code} = 'content_filter';
                    $result->{error_type} = 'content_filter';
                    $result->{error}      = $HORDE_SFW_CENSORED_MSG;
                    $result->{wait_time} = $wait_time if defined $wait_time;
                    $result->{queue_position} = $queue_position if defined $queue_position;
                    return $result;
                }
                my $img = $item->{img};
                next unless defined $img && length $img;
                if (time() >= $deadline) {
                    die "AI Horde image generation timed out\n";
                }
                my $got = $self->_materialize("$img", $idx, $prompt);
                if (!$got->{ok}) {
                    die "$got->{error}\n";
                }
                push @images, $got->{image};
                $idx++;
            }
            if (!@images) {
                die "AI Horde status contained no image payloads\n";
            }
            $completed = 1;
            $result->{ok}     = 1;
            $result->{count}  = scalar @images;
            $result->{images} = \@images;
            $result->{wait_time} = $wait_time if defined $wait_time;
            $result->{queue_position} = $queue_position if defined $queue_position;
            return $result;
        }
    };
    my $eval_err = $@;
    if (!$completed) {
        $self->_cancel($job_id, $headers);
        if (!$result->{error}) {
            my $err = $eval_err || 'AI Horde image generation failed';
            $err =~ s/\s+\z//;
            $result->{error} = $err;
        }
        if ($result->{error} && $result->{error} =~ /no worker picked/i) {
            $result->{error_code} = 'service_unavailable';
            $result->{error_type} = 'service_unavailable';
        }
    }
    return $result;
}

sub _ua ($self) {
    return HTTP::Tiny->new(
        timeout    => $self->{timeout} || $DEFAULT_TIMEOUT,
        max_size   => $self->{max_bytes} || $DEFAULT_MAX_BYTES,
        agent      => 'tubular/0.1',
        verify_SSL => 1,
    );
}

sub _headers ($self) {
    return {
        apikey         => $self->api_key,
        'Client-Agent' => $CLIENT_AGENT,
        Accept         => 'application/json',
        'Content-Type' => 'application/json',
    };
}

sub _sleep ($self, $seconds) {
    return unless defined $seconds && $seconds > 0;
    if (ref $self->{sleep} eq 'CODE') {
        $self->{sleep}->($seconds);
        return;
    }
    select undef, undef, undef, $seconds;
    return;
}

sub _get ($self, $url, $headers) {
    my $ua = $self->_ua;
    my $resp = eval { $ua->get($url, { headers => $headers }) };
    if ($@) {
        return { ok => 0, error => "cannot reach AI Horde at $url: $@" };
    }
    if (!ref $resp || $resp->{status} == 599) {
        my $msg = (ref $resp && defined $resp->{content}) ? $resp->{content} : 'request failed';
        return { ok => 0, error => "cannot reach AI Horde at $url: $msg" };
    }
    if ($resp->{status} !~ /^2\d\d$/) {
        return {
            ok    => 0,
            error => 'AI Horde request failed (HTTP ' . $resp->{status} . '): '
                . _horde_message($resp->{content}, $resp->{reason} // 'request failed'),
        };
    }
    my $decoded = eval { JSON::PP::decode_json($resp->{content} // '') };
    if ($@ || ref $decoded ne 'HASH') {
        return { ok => 0, error => "AI Horde returned malformed JSON: $@" };
    }
    return { ok => 1, json => $decoded };
}

sub _cancel ($self, $job_id, $headers) {
    my $ua = HTTP::Tiny->new(
        timeout    => 10,
        agent      => 'tubular/0.1',
        verify_SSL => 1,
    );
    eval {
        $ua->request('DELETE', $self->{base_url} . "/v2/generate/status/$job_id", {
            headers => $headers,
        });
    };
    return;
}

sub _horde_message ($content, $fallback) {
    if (defined $content && length $content) {
        my $decoded = eval { JSON::PP::decode_json($content) };
        if (ref $decoded eq 'HASH' && defined $decoded->{message} && length "$decoded->{message}") {
            my $msg = "$decoded->{message}";
            $msg =~ s/\s+\z//;
            return $msg;
        }
    }
    return $fallback;
}

sub _materialize ($self, $img, $index, $prompt) {
    if ($img =~ m{\Ahttps?://}i) {
        return $self->_download($img, $index, $prompt);
    }
    my $bytes = MIME::Base64::decode_base64($img);
    if (!defined $bytes || length $bytes == 0) {
        return { ok => 0, error => 'invalid base64 image data' };
    }
    my $ext = _sniff_ext($bytes) // 'webp';
    return {
        ok => 1,
        image => {
            index          => $index,
            kind           => 'b64_json',
            bytes          => \$bytes,
            ext            => $ext,
            revised_prompt => $prompt,
        },
    };
}

sub _download ($self, $url, $index, $prompt) {
    my $ua = $self->_ua;
    my $resp = eval { $ua->get($url) };
    if ($@) {
        return { ok => 0, error => "failed to download image: $@" };
    }
    if (!defined $resp->{content} || $resp->{status} == 599) {
        my $msg = $resp->{content} // 'download failed';
        return { ok => 0, error => "failed to download image: $msg" };
    }
    if ($resp->{status} !~ /^2\d\d$/) {
        return {
            ok => 0,
            error => 'failed to download image: HTTP ' . $resp->{status} . ' '
                . ($resp->{reason} // '') . " for $url",
        };
    }
    my $bytes = $resp->{content} // '';
    if ($bytes eq '') {
        return { ok => 0, error => "failed to download image: empty body from $url" };
    }
    my $content_type = defined $resp->{headers}{'content-type'}
        ? lc $resp->{headers}{'content-type'} : undef;
    $content_type =~ s/;.*// if defined $content_type;
    my $ext = _sniff_ext($bytes);
    $ext = $MIME_EXT{$content_type} if !defined $ext && defined $content_type;
    $ext //= 'png';
    return {
        ok => 1,
        image => {
            index          => $index,
            kind           => 'url',
            url            => $url,
            bytes          => \$bytes,
            ext            => $ext,
            content_type   => $content_type,
            revised_prompt => $prompt,
        },
    };
}

sub _sniff_ext ($bytes) {
    return 'png'  if $bytes =~ /^\x89PNG\r\n\x1a\n/;
    return 'webp' if $bytes =~ /^RIFF.{4}WEBP/s;
    return 'jpg'  if $bytes =~ /^\xff\xd8/;
    return 'gif'  if $bytes =~ /^GIF8[79]a/;
    return undef;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Adapter::Horde - native AI Horde image generation

=head1 SYNOPSIS

    use tubular::Adapter::Horde;

    my $horde = tubular::Adapter::Horde->new(
        timeout => 300,
    );
    my $res = $horde->generate(
        model  => 'aihorde/SDXL 1.0',
        prompt => 'a red sports car beside a mountain lake',
        nsfw   => 0,
        censor_nsfw => 1,
    );

=head1 DESCRIPTION

Talks to the AI Horde native async API (C<POST /api/v2/generate/async>,
then poll C</check> and C</status>) using only C<HTTP::Tiny>. This is the
image path for C<aihorde/*> and C<horde/*> models; it does not go through
OmniRoute.

Request classification is explicit. The default payload sends C<nsfw:false>
and C<censor_nsfw:true> (client-safe SFW). That is job metadata, not a
statement about the model. If a worker then censors the image
(C<generations[].censored>), C<generate> fails with the message
"AI Horde worker censored the generated image because this request was
classified as SFW." instead of writing the placeholder.

The API key is read from C<AI_HORDE_API_KEY> when set; otherwise Horde's
documented anonymous key is used. Keys are never logged.

=cut
