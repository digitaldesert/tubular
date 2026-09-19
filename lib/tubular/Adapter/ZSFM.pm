package tubular::Adapter::ZSFM;

use v5.44;
use warnings;

use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use IO::Select ();
use JSON::PP ();
use File::Spec ();
use Time::HiRes qw(time);

our $VERSION = '0.1';

my $DEFAULT_TIMEOUT = 30;

sub new ($class, %args) {
    my $self = bless {
        timeout => defined $args{timeout} ? $args{timeout} : $DEFAULT_TIMEOUT,
        path    => $args{path},
        runner  => defined $args{runner} ? $args{runner} : 'zsfm',
    }, $class;
    return $self;
}

sub timeout ($self) { return $self->{timeout} }

# Locate the native zsfm executable.
# Explicit --path, then TUBULAR_ZSFM env, then PATH search.
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
        my $candidate = File::Spec->catfile($dir, $runner);
        return $candidate if -x $candidate;
    }
    return undef;
}

# Ask the binary for its version string.
sub version ($self) {
    my $path = $self->find();
    if (!defined $path) {
        return { ok => 0, error => "zsfm not found (searched TUBULAR_ZSFM and \$PATH)" };
    }
    my $res = $self->_run($path, [], '--version');
    return {
        ok      => $res->{exit} == 0 ? 1 : 0,
        path    => $path,
        version => $res->{stdout},
        exit    => $res->{exit},
        stderr  => $res->{stderr},
        error   => $res->{error} || ($res->{exit} == 0 ? undef : "zsfm --version exited $res->{exit}"),
    };
}

# Invoke `zsfm forecast` with a JSON request object on stdin.
#
#   $req = { context => [...], model => 'timesfm', dtype => 'q8', horizon => n }
#
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

    my $json = JSON::PP->new->utf8->canonical->encode($req);
    my $res = $self->_run($path, $json, 'forecast');
    if ($res->{error}) {
        return { ok => 0, error => $res->{error}, path => $path, exit => $res->{exit} };
    }
    if ($res->{exit} != 0) {
        return {
            ok     => 0,
            error  => "zsfm forecast exited $res->{exit}: " . _trim($res->{stderr}),
            path   => $path,
            exit   => $res->{exit},
            stdout => $res->{stdout},
            stderr => $res->{stderr},
        };
    }

    my $decoded = eval { JSON::PP::decode_json($res->{stdout}) };
    if ($@ || ref $decoded ne 'HASH') {
        return {
            ok    => 0,
            error => "zsfm forecast produced invalid JSON: $@",
            path  => $path,
        };
    }
    return {
        ok     => 1,
        path   => $path,
        result => $decoded,
        exit   => 0,
    };
}

# Low-level: run an executable with list-form arguments, write $stdin,
# capture stdout/stderr, enforce a timeout. Never talks to a shell.
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
                print {$in_wr} $stdin;
                close($in_wr);
                $in_done = 1;
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

1;

__END__

=encoding utf8

=head1 NAME

tubular::Adapter::ZSFM - safe integration with the native zsfm CLI

=head1 SYNOPSIS

    use tubular::Adapter::ZSFM;

    my $zsfm = tubular::Adapter::ZSFM->new(timeout => 30);
    my $req = { context => [1,2,3], model => 'timesfm', dtype => 'q8', horizon => 1 };
    my $res = $zsfm->forecast($req);
    say $res->{result}{forecast}[0] if $res->{ok};

=head1 DESCRIPTION

The B<zsfm> executable is located on B<TUBULAR_ZSFM> or C<PATH> (a full path
may be passed to C<new>). The adapter speaks JSON over stdin/stdout:

=over 4

=item * version: C<zsfm --version>

=item * forecast: C<zsfm forecast> with a JSON request
C<{ context, model, dtype, horizon }> on stdin, JSON result on stdout

=back

Process invocation uses list-form execution (never a shell), captures
stdout and stderr and enforces a hard timeout. While C<TUBULAR_INTEGRATION>
is unset the adapter refuses to start the real model so that unit tests can
mock the boundary without a native binary; set C<TUBULAR_INTEGRATION=1> to
run a real integration.

=cut