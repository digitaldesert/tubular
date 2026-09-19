package tubular::Forecast;

use v5.44;
use warnings;

use tubular::Backtest ();

our $VERSION = '0.1';

my $AUTO_CATEGORICAL_MAX_UNIQUE = 12;

# Deterministic forecasting for an ordered numeric sequence.
#
# All estimates are computed in Perl from the observed data only. There is
# no hidden model and no fabricated value: every estimate below is a value
# that actually occurred in the input, and every probability is an empirical
# count ratio labelled as such.
sub forecast ($class, %args) {
    my $values = $args{values};
    my $mode   = defined $args{mode}   ? $args{mode}   : 'auto';
    my $res = {
        ok        => 1,
        n         => scalar @$values,
        unique    => undef,
        error     => undef,
        mode      => $mode,
        horizon   => $args{horizon} // 1,
        steps     => [],
        methods   => [],
        context   => undef,
    };

    if (!@$values) {
        $res->{ok}    = 0;
        $res->{error} = 'empty sequence';
        return $res;
    }
    my $horizon = $res->{horizon};
    if ($horizon !~ /^\d+$/ || $horizon < 1) {
        $res->{ok}    = 0;
        $res->{error} = 'horizon must be a positive integer';
        return $res;
    }
    my $top = defined $args{top} ? $args{top} : 2;

    my %uniq;
    $uniq{"$_"} = 1 for @$values;
    my @distinct = sort { $a <=> $b } map { 0 + $_ } keys %uniq;
    $res->{unique} = scalar @distinct;

    if ($mode eq 'auto') {
        $mode = @distinct <= $AUTO_CATEGORICAL_MAX_UNIQUE ? 'categorical' : 'numeric';
    }
    if ($mode ne 'categorical' && $mode ne 'numeric') {
        $res->{ok}    = 0;
        $res->{error} = "unknown mode '$mode' (expected auto, numeric or categorical)";
        return $res;
    }
    $res->{mode} = $mode;

    my $last       = $values->[-1];
    my $last_index = scalar @$values;    # 1-based position
    $res->{context} = $mode eq 'categorical'
        ? {
            value    => $last,
            position => $last_index,
            note     => 'last observed value used as conditioning context',
          }
        : {
            value    => undef,
            position => undef,
            note     => 'numeric mode does not condition on a single value; it weights observed values by empirical frequency',
          };

    my %seen_method;
    my $step_context = $last;

    for my $s (1 .. $horizon) {
        my ($estimates, $method, $ctx_used);
        if ($mode eq 'categorical') {
            $ctx_used = $s == 1 ? $last : $step_context;
            ($estimates, $method) = _markov_step($values, $ctx_used);
            if (!@$estimates) {
                # No observed transition from the context value: fall back to
                # the global empirical distribution (data only).
                ($estimates, $method) = _histogram_step($values, 0);
            }
        }
        else {
            ($estimates, $method) = _histogram_step($values, $s > 1);
        }
        $step_context = @$estimates ? $estimates->[0]{value} : undef;

        my @e = sort { $b->{p} <=> $a->{p} || $a->{value} <=> $b->{value} } @$estimates;
        splice @e, $top if $top =~ /^\d+$/ && $top >= 1;

        push @{ $res->{steps} }, {
            step      => $s,
            method    => $method,
            label     => 'empirical',
            context   => (defined $ctx_used ? $ctx_used : undef),
            estimates => \@e,
        };
        $seen_method{$method} = 1;
    }

    $res->{methods} = [ sort keys %seen_method ];
    return $res;
}

# Ensemble forecast: combine the deterministic methods with weights derived
# from their rolling backtest error.
#
# Formula (documented): each method m gets weight
#
#   w_m = ( 1 / (1 + mae_m) ) / sum_j ( 1 / (1 + mae_j) )
#
# over the last `min_train..n` positions of the input. Methods that scored no
# backtest position get weight 0; if nobody scored any, the documented
# fallback is equal weights. Each horizon step is the probability-weighted
# mixture of the methods' candidate distributions (last and mean are point
# masses; markov1 and histogram are empirical count ratios), normalised to a
# probability distribution, ranked by p then by value. Later steps condition
# on the previous step's top combined candidate.
sub ensemble ($class, %args) {
    my $values = $args{values};
    my $res = {
        ok           => 1,
        n            => scalar @$values,
        unique       => undef,
        error        => undef,
        mode         => 'ensemble',
        horizon      => $args{horizon} // 1,
        top          => defined $args{top} ? $args{top} : 2,
        steps        => [],
        methods      => [],
        weights      => {},
        weight_source => 'backtest inverse-MAE (w = 1/(1+mae))',
        fallback     => undef,
    };

    if (!@$values) {
        $res->{ok}    = 0;
        $res->{error} = 'empty sequence';
        return $res;
    }
    my $horizon = $res->{horizon};
    if ($horizon !~ /^\d+$/ || $horizon < 1) {
        $res->{ok}    = 0;
        $res->{error} = 'horizon must be a positive integer';
        return $res;
    }
    my $top = $res->{top};
    my @methods = $args{methods} ? @{ $args{methods} } : qw(last mean markov1 histogram);

    my %uniq;
    $uniq{"$_"} = 1 for @$values;
    $res->{unique} = scalar keys %uniq;
    my $last       = $values->[-1];
    $res->{context} = {
        value    => $last,
        position => scalar @$values,
        note     => 'ensemble conditions step 1 on the last observed value; later steps on the previous step\'s top combined candidate',
    };

    my $window       = defined $args{window}      ? $args{window}      : 100;
    my $min_train    = defined $args{min_train}   ? $args{min_train}   : 10;
    my $max_positions = defined $args{max_positions} ? $args{max_positions} : 1000;
    my $mp = $class->_safe_min_train($values, $min_train);

    my $bt = tubular::Backtest->evaluate(
        values        => $values,
        window        => $window,
        min_train     => $mp,
        top           => 1,
        methods       => \@methods,
        max_positions => $max_positions,
    );
    if (!$bt->{ok}) {
        $res->{ok}    = 0;
        $res->{error} = "ensemble backtest failed: $bt->{error}";
        return $res;
    }

    my %w;
    my $total = 0;
    for my $m (@{ $bt->{methods} }) {
        next unless defined $m->{mae} && $m->{positions} > 0;
        my $w = 1 / (1 + $m->{mae});
        $w{$m->{method}} = $w;
        $total += $w;
    }
    if ($total <= 0) {
        $res->{fallback} = 'equal weights (no method scored any backtest position)';
        my $k = scalar @methods;
        $w{$_} = 1 / $k for @methods;
    }
    else {
        $w{$_} = $w{$_} / $total for keys %w;
    }
    $res->{weights} = { map { $_ => 0 + $w{$_} } sort keys %w };

    my $step_context = $last;
    for my $s (1 .. $horizon) {
        my $ctx = $s == 1 ? $last : $step_context;
        my %support;
        for my $m (@methods) {
            my $est = $class->_ensemble_method_step($m, $values, $ctx);
            my $wg = $w{$m} // 0;
            for my $e (@$est) {
                $support{"$e->{value}"} = ($support{"$e->{value}"} // 0) + $wg * $e->{p};
            }
        }
        my @e = map { { value => 0 + $_, p => $support{"$_"} } } sort { $a <=> $b } keys %support;
        my $sum = 0;
        $sum += $_->{p} for @e;
        if (@e && $sum > 0) {
            $_->{p} /= $sum for @e;
        }
        @e = sort { $b->{p} <=> $a->{p} || $a->{value} <=> $b->{value} } @e;
        splice @e, $top if $top =~ /^\d+$/ && $top >= 1;
        $step_context = @e ? $e[0]{value} : undef;

        push @{ $res->{steps} }, {
            step      => $s,
            method    => 'ensemble',
            label     => 'empirical',
            context   => (defined $ctx ? $ctx : undef),
            estimates => \@e,
        };
    }
    $res->{methods} = ['ensemble'];
    return $res;
}

sub _safe_min_train ($class, $values, $min_train) {
    $min_train = scalar @$values - 1 if $min_train > @$values - 1;
    $min_train = 1 if $min_train < 1;
    return $min_train;
}

# Candidate distribution {value,p} for one ensemble member at the current
# step. Point-mass methods carry p = 1; the mixture normalisation in the
# caller keeps the sum at 1.
sub _ensemble_method_step ($class, $m, $values, $ctx) {
    if ($m eq 'last') {
        return [ { value => $values->[-1], p => 1 } ];
    }
    if ($m eq 'mean') {
        my $sum = 0;
        $sum += $_ for @$values;
        return [ { value => $sum / scalar @$values, p => 1 } ];
    }
    if ($m eq 'markov1') {
        my ($est, $method) = _markov_step($values, $ctx);
        return $est;
    }
    if ($m eq 'histogram') {
        my ($est, $method) = _histogram_step($values, 0);
        return $est;
    }
    return [];
}

# Markov first-order: empirical distribution of the next value given $ctx.
# Returns (listref of {value,p}, method) or ([], 'markov1') when $ctx never
# appears with a successor. Falls back to the global histogram on the fly.
# Deterministic: ties broken by numeric order below in the caller.
sub _markov_step ($values, $ctx) {
    return ([], 'markov1') unless defined $ctx;
    my %succ;
    my $seen_ctx = 0;
    for my $i (0 .. $#$values - 1) {
        next unless $values->[$i] == $ctx;
        $seen_ctx = 1;
        $succ{"$values->[$i + 1]"}++;
    }
    return ([], 'markov1') unless $seen_ctx;
    my $total = 0;
    $total += $_ for values %succ;
    my @out = sort { $a <=> $b } map { 0 + $_ } keys %succ;
    return ( [ map { { value => $_, p => $succ{"$_"} / $total } } @out ], 'markov1' );
}

# Global/recent empirical histogram as a standing distribution.
# Returns a listref of {value,p} and the method label.
sub _histogram_step ($values, $recent_only) {
    my $start;
    if ($recent_only && @$values > 100) {
        $start = @$values - 100;
    }
    else {
        $start = 0;
    }
    my @slice = @$values[ $start .. $#$values ];
    my %count;
    $count{"$_"}++ for @slice;
    my $total = scalar @slice;
    my @out = sort { $a <=> $b } map { 0 + $_ } keys %count;
    my $method = $recent_only && $start > 0 ? 'recent-histogram' : 'histogram';
    return ( [ map { { value => $_, p => $count{"$_"} / $total } } @out ], $method );
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Forecast - deterministic forecasts for ordered sequences

=head1 SYNOPSIS

    use tubular::Forecast;

    my $res = tubular::Forecast->forecast(
        values  => [ 3, 1, 4, 1, 5, 9, 2 ],
        mode    => 'auto',
        horizon => 2,
        top     => 3,
    );

    for my $step (@{ $res->{steps} }) {
        say "step $step->{step}: $step->{method}";
        say "  $_->{value} $_->{p}" for @{ $step->{estimates} };
    }

=head1 DESCRIPTION

Produces a step-by-step forecast over the next C<horizon> values. All
probabilities are B<empirical>: each is the observed count ratio inside the
input, and each candidate value actually occurs in the input. Nothing is
fabricated and no hidden model is applied.

Method selection:

=over 4

=item * C<categorical> mode conditions on the last observed value using
first-order Markov counts (B<markov1>). When the context value never
appears with a successor the forecast falls back to the global empirical
histogram. Later steps extend deterministically: each step's best estimate
becomes the next step's context.

=item * C<numeric> mode emits the empirical histogram of observed values
(B<histogram>), using only the last 100 observations for steps after the
first (B<recent-histogram>) when more than 100 values are present.

=item * C<auto> picks C<categorical> when the input has at most 12 distinct
values, C<numeric> otherwise.

=back

The returned result includes the conditioning C<context> used, a human
label of B<empirical> per step, the method that produced each step, and
the distinct list of methods used.

=head1 ENSEMBLE

C<< tubular::Forecast->ensemble(...) >> combines the deterministic methods
B<last>, B<mean>, B<markov1> and B<histogram> into a single forecast whose
weights come from a rolling backtest on the same input (see
L<tubular::Backtest>). The documented formula is

    w_m = ( 1 / (1 + mae_m) )
          / sum_j ( 1 / (1 + mae_j) )

over the scored backtest positions. Methods that scored no position get
weight 0; if no method scored anything, the documented fallback is equal
weights (reported under B<fallback>). Each horizon step is the mixture of
the members' candidate distributions (C<last> and C<mean> are point masses,
C<markov1> and C<histogram> are empirical ratios), normalised to sum to 1,
ranked by probability then by value. Step 1 conditions on the last observed
value; later steps condition on the previous step's top combined candidate.

=cut