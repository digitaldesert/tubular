package tubular::Backtest;

use v5.44;
use warnings;

our $VERSION = '0.1';

# Rolling historical evaluation of deterministic forecasters.
#
# Sliding over the observed sequence, each method sees only the values up to
# the current position (plus, at most, `window` trailing ones) and is asked
# to predict the immediately following value. The true value is compared to
# the prediction to accumulate MAE, RMSE and top-N hit rates. This never
# peeks at the future: each training slice ends strictly before the position
# being predicted.
sub evaluate ($class, %args) {
    my $values = $args{values};
    my $res = {
        ok          => 1,
        n           => scalar @$values,
        error       => undef,
        window      => defined $args{window} ? $args{window} : 100,
        min_train   => defined $args{min_train} ? $args{min_train} : 10,
        top         => defined $args{top} ? $args{top} : 1,
        seed        => $args{seed},
        positions   => 0,
        methods     => [],
        predictions => [],
    };

    if (!@$values || @$values < 2) {
        $res->{ok}    = 0;
        $res->{error} = 'need at least 2 values for a backtest';
        return $res;
    }
    if ($res->{min_train} !~ /^\d+$/ || $res->{min_train} < 1
        || $res->{min_train} >= @$values) {
        $res->{ok}    = 0;
        $res->{error} = "min_train must be at least 1 and less than n ($res->{n})";
        return $res;
    }
    if ($res->{window} !~ /^\d+$/ || $res->{window} < 0) {
        $res->{ok}    = 0;
        $res->{error} = 'window must be a non-negative integer (0 = whole history)';
        return $res;
    }
    my $max_positions = defined $args{max_positions} ? $args{max_positions} : 1000;
    if ($max_positions !~ /^\d+$/ || $max_positions < 1) {
        $res->{ok}    = 0;
        $res->{error} = 'max_positions must be a positive integer';
        return $res;
    }

    my @methods = $args{methods} ? @{ $args{methods} } : qw(last mean markov1 histogram);
    push @methods, 'random' if defined $args{seed} && !grep { $_ eq 'random' } @methods;

    # Evaluation positions: 1-based last training index.
    my @pos = ($res->{min_train} - 1) .. (@$values - 2);
    if (@pos > $max_positions) {
        @pos = @pos[ ($#pos - $max_positions + 1) .. $#pos ];
    }
    $res->{positions} = scalar @pos;

    if (defined $args{seed}) {
        srand($args{seed});
    }

    my %acc;
    $acc{$_} = { method => $_, mae => 0, rmse => 0, hits => 0, positions => 0 }
        for @methods;

    for my $pos (@pos) {
        my $start = $res->{window} == 0 ? 0 : max(0, $pos - $res->{window} + 1);
        my @train = @$values[ $start .. $pos ];
        my $actual = $values->[$pos + 1];

        for my $m (@methods) {
            my $preds = $class->_predict($m, \@train, $args{seed}, $res->{top});
            next unless $preds && @$preds;    # e.g. markov1 with no observed successor
            my $pred = $preds->[0]{value};
            my $err = abs($pred - $actual);
            $acc{$m}{mae} += $err;
            $acc{$m}{rmse} += $err * $err;
            my $k = $res->{top} < @$preds ? $res->{top} : scalar @$preds;
            my @top_n = @$preds[ 0 .. ($k - 1) ];
            $acc{$m}{hits} += (grep { "$_->{value}" eq "$actual" } @top_n) ? 1 : 0;
            $acc{$m}{positions}++;
        }
    }

    for my $m (@methods) {
        my $a = $acc{$m};
        $a->{mae}  = $a->{mae} / $a->{positions}          if $a->{positions};
        $a->{rmse} = sqrt($a->{rmse} / $a->{positions})   if $a->{positions};
        $a->{hit_rate} = $a->{positions} ? $a->{hits} / $a->{positions} : undef;
        push @{ $res->{methods} }, $a;
    }

    return $res;
}

sub max ($a, $b) { return $a > $b ? $a : $b }

# Predict the next value given only the training slice. Returns the list of
# top candidate {value,p} hashes produced by the method, most likely first.
sub _predict ($class, $m, $train, $seed, $top) {
    if ($m eq 'last') {
        return [ { value => $train->[-1], p => 1 } ];
    }
    if ($m eq 'mean') {
        my $sum = 0;
        $sum += $_ for @$train;
        return [ { value => $sum / scalar @$train, p => 1 } ];
    }
    if ($m eq 'markov1') {
        my $ctx = $train->[-1];
        my ($est, ) = _markov_top($train, $ctx);
        return $est;
    }
    if ($m eq 'histogram') {
        return _histogram_top($train);
    }
    if ($m eq 'random') {
        return _random_top($train);
    }
    return [];
}

# Ranked top-N of the first-order Markov distribution for $ctx.
sub _markov_top ($train, $ctx) {
    my %succ;
    my $seen = 0;
    for my $i (0 .. $#$train - 1) {
        next unless $train->[$i] == $ctx;
        $seen = 1;
        $succ{"$train->[$i + 1]"}++;
    }
    return ([], 0) unless $seen;
    my $total = 0;
    $total += $_ for values %succ;
    my @out = sort { $b->{p} <=> $a->{p} || $a->{value} <=> $b->{value} }
        map { { value => 0 + $_, p => $succ{"$_"} / $total } } keys %succ;
    return (\@out, 1);
}

sub _histogram_top ($train) {
    my %count;
    $count{"$_"}++ for @$train;
    my $total = scalar @$train;
    my @out = sort { $b->{p} <=> $a->{p} || $a->{value} <=> $b->{value} }
        map { { value => 0 + $_, p => $count{"$_"} / $total } } keys %count;
    return \@out;
}

# Uniform draw over the distinct values of the training slice.
sub _random_top ($train) {
    my %uniq;
    $uniq{"$_"} = 1 for @$train;
    my @vals = sort { $a <=> $b } map { 0 + $_ } keys %uniq;
    return [] unless @vals;
    my $ix = int rand scalar @vals;
    return [ { value => $vals[$ix], p => 1 / scalar @vals } ];
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Backtest - rolling historical evaluation of forecast methods

=head1 SYNOPSIS

    use tubular::Backtest;

    my $res = tubular::Backtest->evaluate(
        values  => [ 1, 2, 3, 2, 1, 2, 3, 2 ],
        window  => 100,          # 0 = whole history
        min_train => 3,
        top     => 1,
        seed    => 42,           # enables the random baseline
    );

    for my $m (@{ $res->{methods} }) {
        say "$m->{method}: mae=$m->{mae} rmse=$m->{rmse} hit_rate=$m->{hit_rate}";
    }

=head1 DESCRIPTION

Evaluates deterministic forecast methods by sliding a training window over
the sequence and scoring each method's one-step-ahead predictions against
the true values that follow.

No look-ahead leakage: the training slice for position C<p> always ends at
C<p> itself; the comparison value C<values[p+1]> is only ever read for
scoring, never for training.

Methods:

=over 4

=item * B<last> - predict the most recent value (persistence baseline)

=item * B<mean> - predict the average of the training slice

=item * B<markov1> - top candidate of the first-order Markov distribution
conditioned on the most recent value (fallback: no candidate when that
value never has a successor in the slice)

=item * B<histogram> - most frequent value in the train slice

=item * B<random> (only with a C<seed>) - uniform draw over the distinct
values of the slice, from a seedable PRNG

=back

Each method reports B<mae>, B<rmse>, B<hits>/B<hit_rate> for the top-N set
(B<top> defaults to 1). Predictions are never future-aware; the random
baseline is reproducible for a given C<seed>.

=cut