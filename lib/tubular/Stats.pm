package tubular::Stats;

use v5.44;
use warnings;

our $VERSION = '0.1';

# Deterministic statistics for an ordered numeric sequence.
#
# All computations stay in Perl. The input array is never sorted; only
# summary tables (medians, histograms) are built from defensive copies.
sub analyze ($class, $values, %args) {
    my $res = {
        ok    => 1,
        n     => scalar @$values,
        error => undef,
    };

    if (!@$values) {
        $res->{ok} = 0;
        $res->{error} = 'empty sequence';
        return $res;
    }

    $res->{values} = [ @$values ];

    my ($min, $max) = ($values->[0], $values->[0]);
    my $sum = 0;
    for my $v (@$values) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
        $sum += $v;
    }
    my $mean = $sum / scalar @$values;

    $res->{min}   = $min;
    $res->{max}   = $max;
    $res->{range} = $max - $min;
    $res->{mean}  = $mean;

    $res->{median} = $class->_median($values);
    $res->{variance} = $class->_population_variance($values, $mean);
    $res->{stddev} = sqrt $res->{variance};

    my $freqs = $class->_frequencies($values);
    $res->{unique} = scalar @$freqs;
    $res->{histogram} = $freqs;
    my $max_count = 0;
    for my $f (@$freqs) { $max_count = $f->{count} if $f->{count} > $max_count }
    my @modes = map { $_->{value} } grep { $_->{count} == $max_count } @$freqs;
    $res->{mode} = $max_count > 1 ? \@modes : [];

    my $window = defined $args{recent} ? $args{recent} : 100;
    $window = scalar @$values if $window > scalar @$values || $window == 0;
    $res->{recent} = {
        window => $window,
        counts => $class->_frequencies([ @$values[ ($#{$values}-$window+1) .. $#$values ] ]),
    };

    $res->{gaps} = $class->_gaps($values);
    $res->{transitions} = $class->_transitions_first($values);
    $res->{transitions2} = $class->_transitions_second($values);
    $res->{streaks} = $class->_streaks($values);

    return $res;
}

sub _median ($class, $values) {
    my @sorted = sort { $a <=> $b } @$values;
    my $n = @sorted;
    return $n % 2
        ? $sorted[($n - 1) / 2]
        : ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2;
}

sub _population_variance ($class, $values, $mean) {
    my $n = scalar @$values;
    my $ss = 0;
    $ss += ($_ - $mean) ** 2 for @$values;
    return $ss / $n;
}

# Frequencies sorted numerically by value (deterministic).
sub _frequencies ($class, $values) {
    my %count;
    for my $v (@$values) {
        $count{"$v"}++;
    }
    my @out;
    for my $k (sort { $a <=> $b } keys %count) {
        push @out, { value => 0 + $k, count => $count{$k}, p => $count{$k} / scalar @$values };
    }
    return \@out;
}

# Gap analysis per value: distance (in positions) between consecutive
# occurrences, the current run (positions since the last occurrence) and
# the average/maximum inter-occurrence gap.
sub _gaps ($class, $values) {
    my %pos;
    for my $i (0 .. $#$values) {
        push @{ $pos{ "$values->[$i]" } }, $i + 1;
    }
    my @out;
    for my $k (sort { $a <=> $b } keys %pos) {
        my @p = @{ $pos{$k} };
        my @gaps;
        push @gaps, $p[$_] - $p[$_ - 1] for 1 .. $#p;
        my ($avg, $max) = (undef, undef);
        if (@gaps) {
            my $s = 0;
            $s += $_ for @gaps;
            $avg = $s / @gaps;
            ($max) = sort { $b <=> $a } @gaps;
        }
        push @out, {
            value        => 0 + $k,
            count        => scalar @p,
            first_at     => $p[0],
            last_at      => $p[-1],
            current_run  => scalar(@$values) - $p[-1],
            avg_gap      => $avg,
            max_gap      => $max,
            gap_history  => \@gaps,
        };
    }
    return \@out;
}

# First-order transitions: count and conditional empirical probability of
# each immediate pair (a -> b).
sub _transitions_first ($class, $values) {
    my %t;
    for my $i (0 .. $#$values - 1) {
        $t{ $values->[$i] }{ $values->[$i + 1] }++;
    }
    my @out;
    for my $a (sort { $a <=> $b } keys %t) {
        my $total = 0;
        $total += $_ for values %{ $t{$a} };
        for my $b (keys %{ $t{$a} }) {
            push @out, {
                from  => 0 + $a,
                to    => 0 + $b,
                count => $t{$a}{$b},
                p     => $t{$a}{$b} / $total,
            };
        }
    }
    @out = sort { $a->{from} <=> $b->{from} || $a->{to} <=> $b->{to} } @out;
    return \@out;
}

# Second-order transitions: count of each triple (a, b) -> c.
sub _transitions_second ($class, $values) {
    my %t;
    for my $i (0 .. $#$values - 2) {
        $t{ $values->[$i] }{ $values->[$i + 1] }{ $values->[$i + 2] }++;
    }
    my @out;
    for my $x (sort { $a <=> $b } keys %t) {
        for my $y (sort { $a <=> $b } keys %{ $t{$x} }) {
            my $total = 0;
            $total += $_ for values %{ $t{$x}{$y} };
            for my $z (sort { $a cmp $b } keys %{ $t{$x}{$y} }) {
                push @out, {
                    a     => 0 + $x,
                    b     => 0 + $y,
                    c     => 0 + $z,
                    count => $t{$x}{$y}{$z},
                    p     => $t{$x}{$y}{$z} / $total,
                };
            }
        }
    }
    @out = sort { $a->{a} <=> $b->{a} || $a->{b} <=> $b->{b} || $a->{c} <=> $b->{c} } @out;
    return \@out;
}

# Runs of identical consecutive values, each run counted exactly once.
sub _streaks ($class, $values) {
    my @runs;
    my $start = 0;
    for my $i (1 .. $#$values) {
        if ($values->[$i] != $values->[$start]) {
            push @runs, $i - $start;
            $start = $i;
        }
    }
    push @runs, scalar(@$values) - $start;

    my %run_len_count;
    $run_len_count{$_}++ for @runs;

    my @dist = sort { $a <=> $b } keys %run_len_count;
    return {
        max          => (sort { $b <=> $a } @runs)[0],
        current      => $runs[-1],
        distribution => [ map { { length => $_, count => $run_len_count{$_} } } @dist ],
    };
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Stats - deterministic statistics for ordered sequences

=head1 SYNOPSIS

    use tubular::Stats;

    my $s = tubular::Stats->analyze([3, 1, 4, 1, 5, 9, 2], recent => 5);
    say $s->{mean};
    say for @{ $s->{histogram} };       # { value, count, p }
    say for @{ $s->{gaps} };            # { value, count, current_run, ... }

=head1 WHAT IS COMPUTED

=over 4

=item * overview: n, min, max, range, mean, median, mode, population
variance and standard deviation, unique count

=item * I<histogram>: per-value frequencies and empirical probabilities,
sorted numerically by value (the sequence itself is never sorted)

=item * I<recent>: same frequencies but restricted to the last C<recent>
values (default 100, capped at n)

=item * I<gaps>: for each value, the distances between consecutive
occurrences (B<gap_history>), the current run since its last occurrence
(B<current_run>) and average/maximum gap

=item * I<transitions>: first-order pair transitions (a -> b) with
conditional empirical probability p = count / total outgoing from a

=item * I<transitions2>: second-order triples (a, b) -> c, similarly

=item * I<streaks>: longest run of identical values, the current trailing
run, and the distribution of run lengths

=back

Every list is emitted in a deterministic order so two identical inputs
produce byte-identical output. Probabilities are always labelled
B<empirical> downstream; there is no hidden model.

=cut