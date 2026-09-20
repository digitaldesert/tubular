package tubular::Image;

use v5.44;
use warnings;

use HTTP::Tiny ();
use JSON::PP ();
use MIME::Base64 ();
use Scalar::Util qw(looks_like_number reftype);

our $VERSION = '0.1';

# OmniRoute exposes an OpenAI-compatible image-generation API:
#   POST {base_url}/images/generations
# The base URL and timeout live in config (image.base_url, image.timeout).
my $DEFAULT_BASE_URL  = 'http://127.0.0.1:20128/v1';
my $DEFAULT_TIMEOUT   = 300;              # seconds (300000 ms effective)
my $DEFAULT_MAX_BYTES = 60_000_000;       # generous cap for base64 images
my $AGENT             = 'tubular/0.1';

my %MIME_EXT = (
    'image/png'  => 'png',
    'image/jpeg' => 'jpg',
    'image/jpg'  => 'jpg',
    'image/webp' => 'webp',
    'image/gif'  => 'gif',
    'image/bmp'  => 'bmp',
    'image/avif' => 'avif',
);

my %IMAGE_EXT = map { $_ => 1 } keys %MIME_EXT, qw(jpeg);

sub new ($class, %args) {
    my $self = bless {
        base_url  => defined $args{base_url}  ? $args{base_url}  : $DEFAULT_BASE_URL,
        timeout   => defined $args{timeout}   ? $args{timeout}   : $DEFAULT_TIMEOUT,
        max_bytes => defined $args{max_bytes} ? $args{max_bytes} : $DEFAULT_MAX_BYTES,
        api_key   => $args{api_key},
    }, $class;
    return $self;
}

# The API key is never hard-coded: it comes from OMNIROUTE_API_KEY.
sub api_key ($self) {
    if (defined $self->{api_key} && length $self->{api_key}) {
        return $self->{api_key};
    }
    if (defined $ENV{OMNIROUTE_API_KEY} && length $ENV{OMNIROUTE_API_KEY}) {
        return $ENV{OMNIROUTE_API_KEY};
    }
    return undef;
}

# Request one batch of images against the OpenAI-compatible image endpoint.
#
#   $req = {
#     model           => 'aihorde/SDXL 1.0',   # required
#     prompt          => '...',                # required
#     n               => 1,                    # optional positive integer
#     size            => '1024x1024',          # optional
#     quality         => 'high',               # optional
#     seed            => 42,                   # optional
#     output_format   => 'png',                # optional
#     negative_prompt => '...',                # optional, backend-dependent
#   }
#
# Returns { ok => 1, model, base_url, requested_n, images => [ ... ] } where
# each image is
#   { index, kind => 'b64_json'|'url', bytes => \$raw, ext, content_type,
#     revised_prompt, url }.
# Base64 payloads are decoded and URL payloads are downloaded before the
# call returns, so a failure anywhere (missing image data, invalid base64,
# failed download) fails the whole request without partial writes.
sub generate ($self, %req) {
    my $model  = $req{model};
    my $prompt = $req{prompt};

    if (!defined $model || ref $model || $model eq '') {
        return { ok => 0, error => 'model is required' };
    }
    if (!defined $prompt || ref $prompt) {
        return { ok => 0, error => 'prompt is required' };
    }
    if ($prompt eq '') {
        return { ok => 0, error => 'prompt must not be empty' };
    }

    my $key = $self->api_key;
    if (!defined $key) {
        return { ok => 0, error => 'OMNIROUTE_API_KEY is not set (export it before running)' };
    }

    my $base_url = $self->{base_url} // $DEFAULT_BASE_URL;
    $base_url =~ s{/+\z}{};
    my $endpoint = "$base_url/images/generations";

    my %body = (model => $model, prompt => $prompt);
    for my $field (qw(n size quality seed output_format negative_prompt)) {
        $body{$field} = $req{$field} if defined $req{$field};
    }
    if (defined $body{n}) {
        if (!looks_like_number($body{n}) || "$body{n}" !~ /^\d+$/ || $body{n} < 1) {
            return { ok => 0, error => 'n must be a positive integer' };
        }
        $body{n} = 0 + $body{n};
    }
    if (defined $body{seed}) {
        if (!looks_like_number($body{seed}) || "$body{seed}" !~ /^-?\d+$/) {
            return { ok => 0, error => 'seed must be an integer' };
        }
        $body{seed} = 0 + $body{seed};
    }

    my $json = JSON::PP->new->utf8->canonical->encode(\%body);
    my $ua = HTTP::Tiny->new(
        timeout    => $self->{timeout} || $DEFAULT_TIMEOUT,
        max_size   => $self->{max_bytes} || $DEFAULT_MAX_BYTES,
        agent      => $AGENT,
        verify_SSL => 1,
    );

    my $resp = eval {
        $ua->post($endpoint, {
            headers => {
                Authorization => "Bearer $key",
                'Content-Type' => 'application/json',
            },
            content => $json,
        });
    };

    my $result = {
        ok         => 0,
        model      => $model,
        base_url   => $base_url,
        endpoint   => $endpoint,
        requested_n => defined $body{n} ? $body{n} : 1,
    };

    if ($@) {
        $result->{error} = "cannot reach OmniRoute at $endpoint: $@";
        return $result;
    }
    if (!ref $resp || $resp->{status} == 599) {
        my $msg = (ref $resp && defined $resp->{content}) ? $resp->{content} : 'request failed';
        if ($msg =~ /maximum allowed/i) {
            $result->{error} = 'OmniRoute image response is too large';
        }
        else {
            $result->{error} = "cannot reach OmniRoute at $endpoint: $msg";
        }
        return $result;
    }
    $result->{http_status} = $resp->{status};

    if ($resp->{status} !~ /^2\d\d$/) {
        my ($emsg, $ecode, $etype) = _api_error($resp->{content});
        my $status = 'HTTP ' . $resp->{status};
        my $msg    = $emsg;
        if (defined $msg) {
            $msg .= _worker_hint($msg);
        }
        else {
            $msg = $resp->{reason} // 'request failed';
        }
        $result->{error} = 'OmniRoute API error (' . $status
            . ($ecode ? ", $ecode" : '')
            . '): ' . $msg;
        $result->{error_code} = $ecode if defined $ecode;
        $result->{error_type} = $etype if defined $etype;
        return $result;
    }

    my $decoded = eval { JSON::PP::decode_json($resp->{content} // '') };
    if ($@ || ref $decoded ne 'HASH') {
        $result->{error} = "OmniRoute returned malformed JSON: $@";
        return $result;
    }

    my ($wait_time, $queue_position) = _queue_info($decoded);

    my $data = $decoded->{data};
    if (ref $data ne 'ARRAY' && ref $decoded->{images} eq 'ARRAY') {
        $data = $decoded->{images};
    }
    if (ref $data ne 'ARRAY' || !@$data) {
        if (!defined $wait_time && !defined $queue_position) {
            $result->{error} = 'OmniRoute image response contains no image data';
            return $result;
        }
        $result->{queued} = 1;
        $result->{wait_time} = $wait_time if defined $wait_time;
        $result->{queue_position} = $queue_position if defined $queue_position;
        my $wait = defined $wait_time ? "~$wait_time seconds" : 'unknown';
        my $pos  = defined $queue_position ? "position $queue_position" : 'unknown position';
        $result->{error} = "image request is queued ($wait, $pos) but OmniRoute returned no image data yet";
        return $result;
    }

    $result->{wait_time} = $wait_time if defined $wait_time;
    $result->{queue_position} = $queue_position if defined $queue_position;

    my @images;
    for my $i (0 .. $#$data) {
        my $item = $data->[$i];
        my $img = $self->_materialize($item, $i);
        if (!$img->{ok}) {
            $result->{error} = 'image response item ' . ($i + 1) . ": $img->{error}";
            return $result;
        }
        push @images, $img->{image};
    }

    $result->{ok}     = 1;
    $result->{count}  = scalar @images;
    $result->{images} = \@images;
    return $result;
}

# Turn one item of the data array into ready-to-write bytes.
sub _materialize ($self, $item, $index) {
    my $revised = undef;
    my $b64     = undef;
    my $url     = undef;

    if (ref $item eq 'HASH') {
        $b64     = $item->{b64_json};
        $b64     = $item->{data}   if !defined $b64;
        $b64     = $item->{image}  if !defined $b64;
        $url     = $item->{url};
        $revised = $item->{revised_prompt};
    }
    elsif (defined $item) {
        my $s = "$item";
        if ($s =~ m{\Ahttps?://}i) {
            $url = $s;
        }
        else {
            $b64 = $s;
        }
    }

    if (defined $url && !defined $b64) {
        return $self->_download_image($url, $index, $revised);
    }
    if (defined $b64) {
        return $self->_decode_b64("$b64", $index, $revised);
    }
    return { ok => 0, error => 'image response item has neither base64 data nor a URL' };
}

sub _decode_b64 ($self, $raw, $index, $revised) {
    my $media_type = undef;
    my $payload    = $raw;
    if ($raw =~ m{\Adata:(?:image/([a-zA-Z0-9.+_-]+))?;base64,(.*)\z}is) {
        $media_type = defined $1 ? lc $1 : undef;
        $payload    = $2;
    }

    my $bytes = MIME::Base64::decode_base64($payload);
    if (!defined $bytes || length $bytes == 0) {
        return { ok => 0, error => 'invalid base64 image data' };
    }

    my $ext = defined $media_type && $MIME_EXT{$media_type}
        ? $MIME_EXT{$media_type}
        : 'png';

    return {
        ok => 1,
        image => {
            index          => $index,
            kind           => 'b64_json',
            bytes          => \$bytes,
            ext            => $ext,
            content_type   => defined $media_type ? "image/$media_type" : undef,
            revised_prompt => $revised,
        },
    };
}

sub _download_image ($self, $url, $index, $revised) {
    if ($url !~ m{\Ahttps?://}i) {
        return { ok => 0, error => "invalid image URL returned by OmniRoute: $url" };
    }

    my $ua = HTTP::Tiny->new(
        timeout    => $self->{timeout} || $DEFAULT_TIMEOUT,
        max_size   => $self->{max_bytes} || $DEFAULT_MAX_BYTES,
        agent      => $AGENT,
        verify_SSL => 1,
    );
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
        ? lc $resp->{headers}{'content-type'}
        : undef;
    $content_type =~ s/;.*// if defined $content_type;

    my $ext = _ext_from_url($url);
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
            revised_prompt => $revised,
        },
        download_status => $resp->{status},
    };
}

sub _ext_from_url ($url) {
    my ($path) = $url =~ m{\Ahttps?://[^/]+(/[^\#\?]*)?}i;
    return undef unless defined $path;
    my ( $ext ) = $path =~ m{\.([A-Za-z0-9]+)\z};
    return undef unless defined $ext;
    $ext = lc $ext;
    return $IMAGE_EXT{$ext} ? $ext : undef;
}

# OpenAI-compatible endpoint errors come back as { error: { message, code, type } }.
# Returns (message, code, type), each undef when absent.
sub _api_error ($content) {
    my ($msg, $code, $type) = (undef, undef, undef);
    if (defined $content && length $content) {
        my $decoded = eval { JSON::PP::decode_json($content) };
        if (ref $decoded eq 'HASH' && ref $decoded->{error} eq 'HASH') {
            my $e = $decoded->{error};
            $msg  = "$e->{message}" if defined $e->{message};
            $code = "$e->{code}"    if defined $e->{code}    && "$e->{code}" ne '';
            $type = "$e->{type}"    if defined $e->{type}    && "$e->{type}" ne '';
        }
    }
    $msg =~ s/\s+\z// if defined $msg;
    return ($msg, $code, $type);
}

# aihorde models are served through the Horde queue; when no worker picks a
# job up the router reports it so the caller understands it is a queue wait
# rather than a bad request.
sub _worker_hint ($msg) {
    return '' unless defined $msg && $msg =~ /no horde workers/i;
    return ' (aihorde jobs run in a queue; no worker picked this one up - retry in a bit)';
}

# Surfacing of queue state from { wait_time, queue_position } or a
# { queue: { wait_time, position } } payload. Returns (wait_time, queue_position).
sub _queue_info ($decoded) {
    my ($wait_time, $queue_position);
    if (ref $decoded eq 'HASH') {
        $wait_time = $decoded->{wait_time}
            if looks_like_number($decoded->{wait_time});
        $queue_position = $decoded->{queue_position}
            if looks_like_number($decoded->{queue_position});
        if (ref $decoded->{queue} eq 'HASH') {
            my $q = $decoded->{queue};
            $wait_time = $q->{wait_time} if looks_like_number($q->{wait_time});
            $queue_position = $q->{queue_position}
                if looks_like_number($q->{queue_position});
            $queue_position = $q->{position}
                if !defined $queue_position && looks_like_number($q->{position});
        }
        elsif (looks_like_number($decoded->{queue})) {
            $queue_position //= $decoded->{queue};
        }
        if (ref $decoded->{data} eq 'ARRAY' && @{ $decoded->{data} }) {
            my $first = $decoded->{data}[0];
            if (ref $first eq 'HASH') {
                $wait_time = $first->{wait_time}
                    if !defined $wait_time && looks_like_number($first->{wait_time});
                $queue_position = $first->{queue_position}
                    if !defined $queue_position && looks_like_number($first->{queue_position});
            }
        }
    }
    return ($wait_time, $queue_position);
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Image - image generation through the OmniRoute API

=head1 SYNOPSIS

    use tubular::Image;
    use tubular::Config;

    my $config = tubular::Config->new();
    my $image = tubular::Image->new(
        base_url => $config->get('image', 'base_url'),
        timeout  => $config->get('image', 'timeout'),
    );

    my $res = $image->generate(
        model  => 'aihorde/SDXL 1.0',
        prompt => 'a red sports car beside a mountain lake',
    );

    die $res->{error} unless $res->{ok};
    my $bytes = ${ $res->{images}[0]{bytes} };

=head1 DESCRIPTION

A thin, deterministic client for OmniRoute's OpenAI-compatible image
generation endpoint (C<POST /images/generations>). Uses only C<HTTP::Tiny>
for every HTTP exchange and C<JSON::PP> for JSON.

The API key is read from the C<OMNIROUTE_API_KEY> environment variable and is
never hard-coded, logged or echoed. If the variable is missing the caller
gets a clear error.

Request fields are sent only when supplied: C<model> and C<prompt> are
required; C<n>, C<size>, C<quality>, C<seed>, C<output_format> and
C<negative_prompt> are optional and forwarded verbatim (the endpoint is an
OpenAI-compatible router, so a field a particular model does not accept is
rejected by the API itself).

Response handling:

=over 4

=item * base64 image data (C<data[N].b64_json>), including a
C<data:image/...;base64,...> data URI, is decoded on the client;

=item * an image URL (C<data[N].url>) is downloaded with C<HTTP::Tiny>,
its download verified, and the bytes cached client-side.

=back

Every image comes back as raw bytes with a suggested file extension, so the
caller can write files without further HTTP or decoding. If any item in a
multi-image response fails (missing image data, invalid base64, failed
download), the whole request fails rather than returning partial output.

=head2 Queues and wait times

C<aihorde/*> providers generate through the AI Horde queue. When the response
carries queue state - C<wait_time>, C<queue_position>, or a
C<queue: { wait_time, position }> object - it is surfaced on the result as
C<wait_time> and C<queue_position> so callers can report how long a queued
generation is expected to take. If a 2xx response is queued but contains no
image data yet, C<generate> fails with a distinct C<queued> flag (and the
estimated C<wait_time>/C<queue_position>) instead of a vague "no image data"
error.

When no Horde worker picks a job up the router reports a worker-unavailable
error (HTTP 400/503 with a message about Horde workers). Such errors carry the
structured C<error_code>/C<error_type> fields from the API payload and the
message includes a hint that this is a queue wait, not an argument error.

=cut