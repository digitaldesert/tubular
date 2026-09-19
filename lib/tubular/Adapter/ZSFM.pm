package tubular::Adapter::ZSFM;

use v5.44;
use warnings;

use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use IO::Select ();
use JSON::PP ();
use File::Spec ();
use Time::HiRes qw(time);
use Scalar::Util qw(looks_like_number);

our $VERSION = '0.2';

# Forecast inference can be slow on CPU; the timeout must be configurable
# and generous by default (config forecast.timeout overrides this).
my $DEFAULT_TIMEOUT = 120;

# Model names are passed to the executable as subcommands. Accept only safe
# identifiers; the executable itself rejects unknown subcommands.
my $SAFE_MODEL = qr/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;

sub new ($class, %args) {
    my $self = bless {
        timeout => defined $args{timeout} ? $args{timeout} : $DEFAULT_TIMEOUT,
        path    => $args{path},
        runner  => defined $args{runner} ? $args{runner} : 'zsfm',
        model   => defined $args{model}  ? $args{model}  : 'timesfm',
        gguf    => $args{gguf},
    }, $class;
    return $self;
}

sub timeout ($self) { return $self->{timeout} }

# Locate the native zsfm executable.
# Explicit --path, then config/env TUBULAR_ZSFM, then PATH search.
sub find ($self) {
    if (defined $self->{path} && length $self->{path}) {
        return $self->{path} if -x $self->{path};
        return undef;
    }
    if (defined $ENV{TUBULAR_ZSFM} && length $ENV{TUBULAR_ZSFM}) {
        return $ENV{TUBULAR_ZSFM} if -x $ENV{TUBULAR_ZSFM};
    }
    my $runner = $self->{runner};
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $candidate = File::Spec->catfile($dir, $runner);
        return $candidate if -x $candidate && !-d $candidate;
    }
    return undef;
}

# Deterministic availability probe: is zsfm installed and executable?
sub available ($self) {
    my $path = $self->find();
    if (!defined $path) {
        return { ok => 0, error => 'zsfm not found (searched TUBULAR_ZSFM and $PATH)' };
    }
    return { ok => 1, path => $path };
}

# Identify the binary. The installed zsfm has no --version flag, so a failing
# --version is not a failure: fall back to --help for identification.
sub version ($self) {
    my $path = $self->find();
    if (!defined $path) {
        return { ok => 0, error => 'zsfm not found (searched TUBULAR_ZSFM and $PATH)' };
    }
    my $v = $self->_run($path, undef, '--version');
    if ($v->{exit} == 0) {
        return {
            ok      => 1,
            path    => $path,
            version => _trim($v->{stdout}),
            exit    => 0,
        };
    }
    my $h = $self->_run($path, undef, '--help');
    if ($h->{exit} == 0) {
        return {
            ok      => 1,
            path    => $path,
            version => undef,
            ident   => _first_line($h->{stdout}),
            note    => 'zsfm provides no --version flag; identified via --help',
            exit    => 0,
            stderr  => $v->{stderr},
        };
    }
    return {
        ok      => 0,
        path    => $path,
        version => undef,
        exit    => $h->{exit},
        error   => 'cannot identify zsfm (both --version and --help failed)',
        stderr  => $h->{stderr},
    };
}

# Does this zsfm build provide a <model> subcommand (e.g. timesfm)?
sub supports_model ($self, $model) {
    my $path = $self->find();
    if (!defined $path) {
        return { ok => 0, error => 'zsfm not found' };
    }
    if (!defined $model || $model !~ $SAFE_MODEL) {
        return { ok => 0, path => $path, model => $model,
                 error => "invalid model name '$model'" };
    }
    my $res = $self->_run($path, undef, $model, '--help');
    return {
        ok     => $res->{exit} == 0 ? 1 : 0,
        path   => $path,
        model  => $model,
        exit   => $res->{exit},
        stderr => $res->{stderr},
        error  => $res->{exit} == 0 ? undef : "zsfm provides no '$model' subcommand",
    };
}

# Invoke the native model on a univariate series.
#
#   $req = {
#     context => [ 1, 2, 3, ... ],   # required, numeric, non-empty
#     horizon => 1,                  # positive integer
#     model   => 'timesfm',          # zsfm subcommand
#     gguf    => '/abs/path.gguf',   # required, must exist and be readable
#   }
#
# argv is constructed list-form: [$path, $model, 'infer', '--gguf', $gguf].
# A refusal to run the real binary while TUBULAR_INTEGRATION is unset gives
# the caller a clean, mockable boundary for tests.
sub forecast ($self, $req) {
    my $path = $self->find();
    if (!defined $path) {
        return { ok => 0, error => 'zsfm not found' };
    }
    if (!defined $ENV{TUBULAR_INTEGRATION} || $ENV{TUBULAR_INTEGRATION} eq '') {
        return {
            ok    => 0,
            error => 'real zsfm invocation disabled: set TUBULAR_INTEGRATION=1 to run the native model',
            path  => $path,
        };
    }

    my $bad = $self->_validate_request($req);
    if (defined $bad) {
        return { ok => 0, error => $bad, path => $path };
    }

    my $model   = $req->{model} // $self->{model} // 'timesfm';
    my $gguf    = $req->{gguf}  // $self->{gguf};
    my $horizon = $req->{horizon} // 1;

    my $payload = {
        context => [ map { 0 + $_ } @{ $req->{context} } ],
        horizon => 0 + $horizon,
    };
    my $json = JSON::PP->new->utf8->canonical->encode($payload);

    my $t0 = time();
    my $res = $self->_run($path, $json, $model, 'infer', '--gguf', $gguf);
    my $runtime_ms = int((time() - $t0) * 1000);

    if ($res->{error}) {
        return {
            ok => 0, path => $path, model => $model, gguf => $gguf,
            error => $res->{error}, exit => $res->{exit}, runtime_ms => $runtime_ms,
        };
    }
    if ($res->{exit} != 0) {
        return {
            ok => 0, path => $path, model => $model, gguf => $gguf,
            exit => $res->{exit}, runtime_ms => $runtime_ms,
            stderr => $res->{stderr}, stdout => $res->{stdout},
            error => "zsfm exited $res->{exit}: " . _clip($res->{stderr}),
        };
    }

    my $out = _trim($res->{stdout});
    if ($out eq '') {
        return {
            ok => 0, path => $path, model => $model, gguf => $gguf,
            exit => $res->{exit}, runtime_ms => $runtime_ms,
            stderr => $res->{stderr},
            error => 'zsfm produced no output on stdout',
        };
    }

    my $decoded = eval { JSON::PP::decode_json($out) };
    if ($@ || ref $decoded ne 'HASH') {
        return {
            ok => 0, path => $path, model => $model, gguf => $gguf,
            exit => $res->{exit}, runtime_ms => $runtime_ms,
            stderr => $res->{stderr},
            error => "zsfm produced invalid JSON on stdout: $@",
        };
    }

    my $normalized = $self->_normalize($decoded, $horizon);
    if ($normalized->{error}) {
        return {
            ok => 0, path => $path, model => $model, gguf => $gguf,
            exit => $res->{exit}, runtime_ms => $runtime_ms,
            stderr => $res->{stderr},
            error => $normalized->{error},
        };
    }

    return {
        ok        => 1,
        path      => $path,
        model     => $model,
        gguf      => $gguf,
        exit      => $res->{exit},
        runtime_ms => $runtime_ms,
        stderr    => $res->{stderr},
        result    => $normalized->{result},
    };
}

# Validate the request before touching the executable. Returns an error
# string, or undef when the request is usable.
sub _validate_request ($self, $req) {
    if (ref $req ne 'HASH') {
        return 'request must be a hashref with context, horizon, model and gguf';
    }

    my $model = defined $req->{model} ? $req->{model} : $self->{model};
    if (!defined $model || $model eq '') {
        return 'model name is required';
    }
    if ($model !~ $SAFE_MODEL) {
        return "invalid model name '$model'";
    }

    my $gguf = defined $req->{gguf} ? $req->{gguf} : $self->{gguf};
    if (!defined $gguf || $gguf eq '') {
        return 'no GGUF model path supplied (use --gguf or config forecast.gguf)';
    }
    if (!-e $gguf || !-f $gguf) {
        return "GGUF model not found: $gguf (set up the model with 'bin/models setup')";
    }
    if (!-r $gguf) {
        return "GGUF model is not readable: $gguf";
    }

    my $context = $req->{context};
    if (ref $context ne 'ARRAY') {
        return 'context must be an array of numbers';
    }
    if (!@$context) {
        return 'context must not be empty';
    }
    for my $v (@$context) {
        if (!defined $v || !looks_like_number($v)) {
            return "context must contain only numbers, got '"
                . (defined $v ? $v : 'undef') . "'";
        }
    }

    my $horizon = defined $req->{horizon} ? $req->{horizon} : 1;
    if ($horizon !~ /^\d+$/ || $horizon < 1) {
        return 'horizon must be a positive integer';
    }

    return undef;
}

# Reduce the raw zsfm stdout into one stable Tubular-side shape:
#
#   { model, point, quantiles, raw_model, runtime_ms }
#
# Raw "OpenAI-compatible" output may nest the forecast object under
# `forecast` (hash or one-element list); point may be a flat series for a
# univariate request or a one-element nested series. `point_length`, when
# present, trims trailing padding. Quantiles are kept only when the runtime
# actually returned them - nothing is invented.
sub _normalize ($self, $decoded, $horizon) {
    my $container = $decoded;
    if (ref $decoded->{forecast} eq 'HASH') {
        $container = $decoded->{forecast};
    }
    elsif (ref $decoded->{forecast} eq 'ARRAY'
        && ref $decoded->{forecast}[0] eq 'HASH') {
        $container = $decoded->{forecast}[0];
    }

    my $points = $container->{point};
    if (ref $container->{point} eq 'ARRAY'
        && @{ $container->{point} }
        && ref $container->{point}[0] eq 'ARRAY') {
        $points = $container->{point}[0];    # univariate single series
    }

    if (ref $points ne 'ARRAY' || !@$points) {
        return { error => 'zsfm response contains no forecast point series' };
    }
    my @p = @$points;
    if (defined $container->{point_length}
        && $container->{point_length} =~ /^\d+$/) {
        my $keep = $container->{point_length};
        $keep = @p if $keep > @p;
        @p = @p[0 .. $keep - 1];
    }
    if (@p != $horizon) {
        return { error => "expected $horizon forecast points, got " . scalar @p };
    }

    my $quantiles;
    if (ref $container->{quantiles} eq 'HASH'
        && scalar keys %{ $container->{quantiles} }) {
        $quantiles = { %{ $container->{quantiles} } };
        for my $q (keys %$quantiles) {
            if (ref $quantiles->{$q} eq 'ARRAY') {
                @{ $quantiles->{$q} } = @{ $quantiles->{$q} }[0 .. $horizon - 1]
                    if @{ $quantiles->{$q} } > $horizon;
            }
        }
    }

    my $model_name = $decoded->{model};
    $model_name = $container->{model} if !defined $model_name;

    return {
        result => {
            model      => (defined $model_name ? "$model_name" : undef),
            point      => \@p,
            quantiles  => $quantiles,
            raw_model  => $decoded,
        },
        error => undef,
    };
}

# Low-level: run an executable with list-form arguments, write $stdin,
# capture stdout and stderr separately, enforce a timeout. Never talks to
# a shell. stdout and stderr are drained concurrently so large diagnostics
# cannot deadlock against a full stdout pipe.
sub _run ($self, $path, $stdin, @argv) {
    my $timeout = $self->{timeout};
    my $err_rd = gensym();
    my $start = time();

    my ($in_wr, $out_rd, $pid);
    eval {
        $pid = open3($in_wr, $out_rd, $err_rd, $path, @argv);
    };
    if ($@) {
        return { exit => undef, error => "cannot start $path: $@" };
    }

    my $out = '';
    my $err = '';
    my $have_stdin = defined $stdin && $stdin ne '';
    close($in_wr) unless $have_stdin;

    my $in_done = !$have_stdin;
    my $sel = IO::Select->new($out_rd, $err_rd);
    my $deadline = $start + $timeout;
    my $timed_out = 0;

    while ($sel->count()) {
        my $left = $deadline - time();
        if ($left <= 0) { $timed_out = 1; last }

        if (!$in_done) {
            my @w = IO::Select->new($in_wr)->can_write($left);
            if (@w) {
                my $n = print {$in_wr} $stdin;
                if ($n) {
                    close($in_wr);
                    $in_done = 1;
                }
            }
        }

        my @r = $sel->can_read(0.25);
        for my $h (@r) {
            my $buf = '';
            my $n = sysread($h, $buf, 65536);
            if (!defined $n || $n == 0) {
                $sel->remove($h);
                next;
            }
            $out .= $buf if $h == $out_rd;
            $err .= $buf if $h == $err_rd;
        }
    }

    if ($timed_out) {
        _kill_tree($pid);
        return { exit => undef, error => "zsfm timed out after ${timeout}s" };
    }

    # Pipes are closed; reap the child, polling so we still honour the timeout.
    my $exit;
    for (;;) {
        my $w = waitpid($pid, 1);
        if ($w == $pid) { $exit = $? >> 8; last }
        if (time() > $deadline) {
            _kill_tree($pid);
            return { exit => undef, error => "zsfm timed out after ${timeout}s" };
        }
        Time::HiRes::sleep(0.05);
    }

    return {
        exit   => $exit,
        stdout => $out,
        stderr => $err,
        error  => undef,
    };
}

sub _kill_tree ($pid) {
    kill 'TERM', $pid if $pid;
    Time::HiRes::sleep(0.2);
    kill 'KILL', $pid if $pid;
    eval { waitpid $pid, 0 };
}

sub _trim ($s) {
    $s //= '';
    $s =~ s/\s+\z//;
    $s =~ s/\A\s+//;
    return $s;
}

sub _first_line ($s) {
    $s //= '';
    my ($first) = split /\r?\n/, $s;
    $first =~ s/\s+\z//;
    return $first;
}

# Keep user-facing errors short; full stderr is still carried on the result.
sub _clip ($s) {
    $s //= '';
    $s = _trim($s);
    if (length $s > 1200) {
        $s = substr($s, 0, 1200) . '...';
    }
    return $s;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Adapter::ZSFM - safe integration with the native zsfm CLI

=head1 SYNOPSIS

    use tubular::Adapter::ZSFM;

    my $zsfm = tubular::Adapter::ZSFM->new(timeout => 120);
    my $req = { context => [1,2,3], model => 'timesfm',
                gguf => '/home/me/models/timesfm-q8.gguf', horizon => 1 };
    my $res = $zsfm->forecast($req);
    say $res->{result}{point}[0] if $res->{ok};

=head1 DESCRIPTION

The B<zsfm> executable is located via an explicit C<path>, the
C<TUBULAR_ZSFM> environment variable, then C<PATH> (in that order). The
adapter speaks JSON over stdin/stdout:

=over 4

=item * identify: C<zsfm --version> if supported, else C<zsfm --help>
(the installed zsfm has no C<--version> flag)

=item * model probe: C<zsfm MODEL --help> (e.g. C<zsfm timesfm --help>)

=item * inference: C<zsfm MODEL infer --gguf PATH> with a JSON request
C<{ context, horizon }> on stdin; the response is normalised to a stable
Tubular shape C<< { model, point, quantiles, raw_model } >> (B<quantiles>
are kept only when the runtime actually returned them)

=back

Process invocation uses list-form execution (never a shell), captures
stdout and stderr separately, waits for the child, checks the exit status
and enforces a hard timeout (config C<forecast.timeout>, default 120 s).
Successful runs may still write diagnostics to stderr; that is not treated
as failure when the exit status is zero and stdout parses.

While C<TUBULAR_INTEGRATION> is unset the adapter refuses to start the real
model so that unit tests can mock the boundary without a native binary; set
C<TUBULAR_INTEGRATION=1> to run a real inference.

=head2 Model acquisition is explicit

The adapter only runs inference. It never downloads or converts a model.
If the GGUF path is missing the caller gets a clear error telling it to set
up the model first (see C<bin/models>).

=cut