package tubular::Sequence;

use v5.44;
use warnings;

use Scalar::Util qw(reftype);

our $VERSION = '0.1';

my $NUMBER_RE = qr/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

sub new ($class, @args) {
    my %args = %{ _normalize_args(@args) };
    my $self = bless {
        values   => [],
        tokens   => [],
        warnings => [],
        source   => $args{source},
    }, $class;

    if (defined $args{values}) {
        my $v = $args{values};
        if (reftype($v) ne 'ARRAY') {
            die "tubular::Sequence: values must be an array reference\n";
        }
        for my $n (@$v) {
            die "tubular::Sequence: values must be numeric, got '$n'\n"
                unless $n =~ $NUMBER_RE;
        }
        @{ $self->{values} } = map { 0 + $_ } @$v;
        @{ $self->{tokens} } = map { "$_" } @$v;
    }
    return $self;
}

sub _normalize_args (@args) {
    my %args;
    if (@args == 1) {
        my $arg = $args[0];
        if (defined $arg && ref $arg eq 'HASH') {
            %args = %$arg;
        }
        else {
            $args{values} = $arg;
        }
    }
    elsif (@args % 2 == 0) {
        %args = @args;
    }
    else {
        die "tubular::Sequence: odd number of constructor arguments\n";
    }
    return \%args;
}

sub from_string ($class, $string, %args) {
    my $self = $class->_from_tokens($string, \%args);
    $self->{source} = defined $args{source} ? $args{source} : 'string';
    return $self;
}

sub from_file ($class, $path, %args) {
    die "tubular::Sequence: no such file: $path\n" unless -e $path;
    open my $fh, '<:raw:encoding(UTF-8)', $path
        or die "tubular::Sequence: cannot read $path: $!\n";
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    my $self = $class->_from_tokens($raw, \%args);
    $self->{source} = "file:$path";
    return $self;
}

sub _from_tokens ($class, $string, $args) {
    my $strict = exists $args->{strict} ? $args->{strict} : 1;
    my @tokens = grep { length } split /[\s,]+/, (defined $string ? $string : '');
    my @values;
    my @tokens_kept;
    my @warnings;
    for my $tok (@tokens) {
        if ($tok =~ $NUMBER_RE) {
            push @values, 0 + $tok;
            push @tokens_kept, $tok;
        }
        else {
            my $msg = "malformed number token '$tok'";
            if ($strict) {
                die "tubular::Sequence: $msg\n";
            }
            push @warnings, $msg;
        }
    }
    my $self = bless {
        values   => \@values,
        tokens   => \@tokens_kept,
        warnings => \@warnings,
        source   => 'string',
    }, $class;
    return $self;
}

sub values ($self) {
    return wantarray ? @{ $self->{values} } : $self->{values};
}

sub tokens ($self) {
    return wantarray ? @{ $self->{tokens} } : $self->{tokens};
}

sub count ($self) {
    return scalar @{ $self->{values} };
}

sub min ($self) {
    die "tubular::Sequence: min() on empty sequence\n" unless @{ $self->{values} };
    my $min = $self->{values}[0];
    for my $v (@{ $self->{values} }[1..$#{ $self->{values} }]) {
        $min = $v if $v < $min;
    }
    return $min;
}

sub max ($self) {
    die "tubular::Sequence: max() on empty sequence\n" unless @{ $self->{values} };
    my $max = $self->{values}[0];
    for my $v (@{ $self->{values} }[1..$#{ $self->{values} }]) {
        $max = $v if $v > $max;
    }
    return $max;
}

sub unique_count ($self) {
    my %seen;
    $seen{$_} = 1 for @{ $self->{values} };
    return scalar keys %seen;
}

sub warnings ($self) {
    return wantarray ? @{ $self->{warnings} } : $self->{warnings};
}

sub has_warnings ($self) {
    return @{ $self->{warnings} } ? 1 : 0;
}

sub source ($self) {
    return $self->{source};
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Sequence - ordered numeric sequence

=head1 SYNOPSIS

    use tubular::Sequence;

    my $seq = tubular::Sequence->from_string("1 2, 3\n4", strict => 1);
    say $seq->count;    # 4

    my $f = tubular::Sequence->from_file('example.txt');
    say $f->min;        # smallest value

=head1 DESCRIPTION

Parses ordered numeric data from strings or files. Input may mix whitespace
and commas (`"1 2 3"`, `"1,2,3"`, `"1, 2 3"`, one number per line, and any
combination). Original ordering is always preserved; input is never sorted.

In strict mode (the default) any token that is not a valid number causes
`from_string()` / `from_file()` to die. In non-strict mode malformed tokens
are skipped and reported via `warnings()`.

Values are stored as Perl numbers; the original tokens are kept separately
via `tokens()`.

=cut