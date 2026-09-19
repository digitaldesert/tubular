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

    my $result = {
        url        => $url,
        http_status => undef,
        bytes      => 0,
        sha256     => undef,
        output     => $args{output},
        content    => undef,
        elapsed    => 0,
        ok         => 0,
        error      => undef,
    };

    if (!defined $url || $url !~ m{\Ahttps?://}i) {
        $result->{error} = "invalid URL (only http/https supported): " . (defined $url ? $url : '');
        return $result;
    }

    if (defined $args{output} && -e $args{output} && !$args{force}) {
        $result->{error} = "output exists (use --force to overwrite): $args{output}";
        return $result;
    }

    my $ua = HTTP::Tiny->new(
        timeout     => $timeout,
        max_size    => $max_bytes,
        agent       => $user_agent,
        verify_SSL  => 1,
    );

    my $start = time();
    my $resp = eval { $ua->get($url) };
    $result->{elapsed} = time() - $start;
    if ($@) {
        $result->{error} = "request failed: $@";
        return $result;
    }

    $result->{http_status} = $resp->{status};

    if ($resp->{status} == 599) {
        my $msg = $resp->{content} // 'download failed';
        if (defined $max_bytes && $msg =~ /maximum allowed/i) {
            $result->{error} = "response exceeds max_bytes ($max_bytes): download aborted";
        }
        else {
            $result->{error} = "download failed: $msg";
        }
        return $result;
    }

    if ($resp->{status} !~ /^2\d\d$/) {
        $result->{error} = "HTTP " . $resp->{status} . " "
            . ($resp->{reason} // '') . " for $url";
        return $result;
    }

    my $content = $resp->{content} // '';
    $result->{bytes} = length $content;
    $result->{sha256} = $self->_sha256($content);
    $result->{content} = $content;

    if (defined $args{sha256} && length $args{sha256}) {
        if (lc $args{sha256} ne lc $result->{sha256}) {
            my $got = substr($result->{sha256}, 0, 12);
            my $exp = substr($args{sha256}, 0, 12);
            $result->{error} = "SHA-256 mismatch (expected ...$exp, got ...$got)";
            return $result;
        }
    }

    if (defined $args{output} && length $args{output}) {
        $result->{error} = $self->_write_atomic($args{output}, $content);
        return $result if $result->{error};
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

sub _write_atomic ($self, $target, $content) {
    my $dir = dirname($target);
    my $tmp = File::Spec->catfile($dir, ".tubular-fetch.$$.tmp");
    eval {
        open my $fh, '>:raw', $tmp or die "cannot write $tmp: $!";
        print {$fh} $content or die "cannot write $tmp: $!";
        close $fh or die "cannot close $tmp: $!";
        rename $tmp, $target or die "cannot rename $tmp -> $target: $!";
    };
    if ($@) {
        unlink $tmp if -e $tmp;
        return "write failed for $target: $@";
    }
    return undef;
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

C<fetch> returns a result hashref with C<ok>, C<error>, C<http_status>,
C<bytes>, C<sha256>, C<output>, C<content> and C<elapsed>. C<content>
holds the fetched bytes; pass C<--json>-style callers should not print it.
The output file (if requested) is written only after the download and
SHA-256 verification succeed.

=cut