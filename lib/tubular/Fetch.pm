package tubular::Fetch;

use v5.44;
use warnings;

use HTTP::Tiny ();
use Digest::SHA ();
use File::Spec ();
use File::Basename qw(dirname);
use Time::HiRes qw(time);

our $VERSION = '0.1';

sub new ($class, %args) {
    my $self = bless { %args }, $class;
    return $self;
}

sub fetch ($self, $url, %args) {
    my $cfg = $args{config} // {};
    my $timeout    = defined $args{timeout}    ? $args{timeout}    : _cfg($cfg, qw(fetch timeout), 30);
    my $max_bytes  = defined $args{max_bytes}  ? $args{max_bytes}  : _cfg($cfg, qw(fetch max_bytes), 52_428_800);
    my $user_agent = defined $args{user_agent} ? $args{user_agent} : _cfg($cfg, qw(fetch user_agent), 'tubular/0.1');

    my $output = defined $args{output} && length $args{output} ? $args{output} : undef;

    my $result = {
        url         => $url,
        http_status => undef,
        bytes       => 0,
        sha256      => undef,
        output      => $output,
        content     => undef,
        elapsed     => 0,
        ok          => 0,
        error       => undef,
    };

    if (!defined $url || $url !~ m{\Ahttps?://}i) {
        $result->{error} = "invalid URL (only http/https supported): " . (defined $url ? $url : '');
        return $result;
    }

    if (defined $output && -e $output && !$args{force}) {
        $result->{error} = "output exists (use --force to overwrite): $output";
        return $result;
    }

    my $ua = HTTP::Tiny->new(
        timeout     => $timeout,
        max_size    => $max_bytes,
        agent       => $user_agent,
        verify_SSL  => 1,
    );

    # Streaming path: when an output file is requested the body is written
    # incrementally to a temp file (memory-safe for large downloads) instead
    # of being buffered in memory. The temp file is only renamed into place
    # after the download, size check and SHA-256 verification succeed.
    my $tmp = defined $output ? File::Spec->catfile(dirname($output), ".tubular-fetch.$$.tmp") : undef;
    my $fh;
    my $sha = Digest::SHA->new(256);
    my $bytes = 0;
    my $overflow = 0;

    if (defined $tmp) {
        unless (open $fh, '>:raw', $tmp) {
            $result->{error} = "cannot write $tmp: $!";
            return $result;
        }
    }

    my $resp;
    my $start = time();
    if (defined $fh) {
        $resp = eval {
            $ua->get($url, {
                data_callback => sub {
                    my ($chunk) = @_;
                    $bytes += length $chunk;
                    if (defined $max_bytes && $bytes > $max_bytes) {
                        $overflow = 1;
                        return -1;
                    }
                    print {$fh} $chunk or return -1;
                    $sha->add($chunk);
                    return 1;
                },
            });
        };
    }
    else {
        $resp = eval { $ua->get($url) };
    }
    $result->{elapsed} = time() - $start;

    if (defined $fh) {
        unless (close $fh) {
            unlink $tmp if -e $tmp;
            $result->{error} = "write failed for $tmp: $!";
            return $result;
        }
        $fh = undef;
    }

    if ($@) {
        unlink $tmp if defined $tmp && -e $tmp;
        $result->{error} = "request failed: $@";
        return $result;
    }

    $result->{http_status} = $resp->{status};

    if ($overflow) {
        unlink $tmp if defined $tmp && -e $tmp;
        $result->{error} = "response exceeds max_bytes ($max_bytes): download aborted";
        return $result;
    }

    if ($resp->{status} == 599) {
        my $msg = $resp->{content} // 'download failed';
        if (defined $max_bytes && $msg =~ /maximum allowed/i) {
            $result->{error} = "response exceeds max_bytes ($max_bytes): download aborted";
        }
        else {
            $result->{error} = "download failed: $msg";
        }
        unlink $tmp if defined $tmp && -e $tmp;
        return $result;
    }

    if ($resp->{status} !~ /^2\d\d$/) {
        $result->{error} = 'HTTP ' . $resp->{status} . ' '
            . ($resp->{reason} // '') . " for $url";
        unlink $tmp if defined $tmp && -e $tmp;
        return $result;
    }

    if (defined $tmp) {
        $result->{bytes}  = $bytes;
        $result->{sha256} = $sha->hexdigest;
        $result->{content} = undef;
    }
    else {
        my $content = $resp->{content} // '';
        $result->{bytes}  = length $content;
        $result->{sha256} = $self->_sha256($content);
        $result->{content} = $content;
    }

    if (defined $args{sha256} && length $args{sha256}) {
        if (lc $args{sha256} ne lc $result->{sha256}) {
            my $got = substr($result->{sha256}, 0, 12);
            my $exp = substr($args{sha256}, 0, 12);
            $result->{error} = "SHA-256 mismatch (expected ...$exp, got ...$got)";
            unlink $tmp if defined $tmp && -e $tmp;
            return $result;
        }
    }

    if (defined $tmp) {
        unless (rename $tmp, $output) {
            unlink $tmp if -e $tmp;
            $result->{error} = "cannot rename $tmp -> $output: $!";
            return $result;
        }
    }

    $result->{ok} = 1;
    return $result;
}

sub _sha256 ($self, $content) {
    return Digest::SHA::sha256_hex($content);
}

sub _cfg ($cfg, @keys) {
    my $v = $cfg;
    for my $k (@keys) {
        return undef unless ref $v eq 'HASH' && exists $v->{$k};
        $v = $v->{$k};
    }
    return $v;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Fetch - HTTP resource fetching

=head1 SYNOPSIS

    use tubular::Fetch;
    use tubular::Config;

    my $fetch = tubular::Fetch->new;
    my $res = $fetch->fetch($url, output => 'data.bin');

    die $res->{error} unless $res->{ok};

=head1 DESCRIPTION

Fetches a single remote resource over HTTP/HTTPS using C<HTTP::Tiny>.
This is not a crawler; links are never followed.

Behaviour:

=over 4

=item * configurable timeout, byte limit and user agent

=item * optional SHA-256 verification

=item * downloads to a temporary file, then atomically renames

=item * refuses to overwrite an existing output unless C<force> is set

=item * never executes downloaded content

=back

When an C<output> file is requested the body is streamed incrementally to a
temp file (memory-safe for large downloads) and C<content> is left undefined;
otherwise the body is buffered and returned via C<content>. Either way the
result carries C<ok>, C<error>, C<http_status>, C<bytes>, C<sha256>,
C<output> and C<elapsed>. The output file (if requested) is written only
after the download, size check and SHA-256 verification succeed.

=cut