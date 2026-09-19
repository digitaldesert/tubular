package tubular::Extract;

use v5.44;
use warnings;

use tubular::Sequence ();
use tubular::Reader::Text ();
use tubular::Reader::CSV ();
use tubular::Reader::PDF ();

our $VERSION = '0.1';

my $NUMBER_RE = qr/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;

# Determine input type from the file extension.
sub detect_type ($class, $path) {
    return 'pdf'  if $path =~ /\.pdf$/i;
    return 'csv'  if $path =~ /\.csv$/i;
    return 'text' if $path =~ /\.(?:txt|text|dat|log|asc)$/i;
    return 'unknown';
}

# Extract values or text from an input file.
#
#   $res = tubular::Extract->extract($path,
#       mode       => 'numbers' | 'text',     # default numbers
#       pages      => '1-3,5',                 # PDF only
#       column     => $name | $index,          # CSV only
#       strict     => 0 | 1,                   # default from config
#       csv_header => 'auto'|'always'|'never', # default from config
#   );
sub extract ($class, $path, %args) {
    my $type = $class->detect_type($path);
    my $mode = defined $args{mode} ? $args{mode} : 'numbers';
    my $strict = exists $args{strict} ? $args{strict} : 1;

    $args{strict} = $strict;
    $args{csv_header} = 'auto' unless exists $args{csv_header};

    my $result = {
        ok       => 0,
        type     => $type,
        mode     => $mode,
        source   => $path,
        values   => [],
        text     => undef,
        pages    => [],
        warnings => [],
        error    => undef,
    };

    if ($type eq 'unknown') {
        $result->{error} = "unsupported file type for $path (expected .txt, .text, .dat, .log, .asc, .csv or .pdf)";
        return $result;
    }

    if ($type ne 'pdf' && defined $args{pages} && length $args{pages}) {
        $result->{error} = "--pages is only valid for PDF input";
        return $result;
    }

    if ($mode ne 'numbers' && $mode ne 'text') {
        $result->{error} = "unknown mode '$mode' (expected numbers or text)";
        return $result;
    }

    if ($type eq 'pdf') {
        return $class->_extract_pdf($result, $path, %args);
    }
    if ($type eq 'text') {
        return $class->_extract_text($result, $path, %args);
    }
    return $class->_extract_csv($result, $path, %args);
}

sub _extract_text ($class, $result, $path, %args) {
    if ($result->{mode} eq 'text') {
        my $raw = eval { tubular::Reader::Text->text($path) };
        if ($@) {
            $result->{error} = $@;
            return $result;
        }
        $result->{text} = $raw;
        $result->{ok} = 1;
        return $result;
    }

    my $seq = eval { tubular::Reader::Text->sequence($path, strict => $args{strict}) };
    if ($@) {
        $result->{error} = $@;
        return $result;
    }
    $result->{values} = [ $seq->values ];
    push @{ $result->{warnings} }, $seq->warnings;
    $result->{ok} = 1;
    return $result;
}

sub _extract_pdf ($class, $result, $path, %args) {
    my $pdf = tubular::Reader::PDF->pages($path, pages => $args{pages});
    if ($pdf->{error}) {
        $result->{error} = $pdf->{error};
        return $result;
    }
    $result->{pages} = $pdf->{pages};
    push @{ $result->{warnings} }, @{ $pdf->{warnings} };
    $result->{text} = $pdf->{text};

    if ($result->{mode} eq 'text') {
        $result->{ok} = 1;
        return $result;
    }

    my $seq = eval { tubular::Sequence->from_string($pdf->{text}, strict => $args{strict}) };
    if ($@) {
        $result->{error} = $@;
        return $result;
    }
    $result->{values} = [ $seq->values ];
    push @{ $result->{warnings} }, $seq->warnings;
    $result->{ok} = 1;
    return $result;
}

sub _extract_csv ($class, $result, $path, %args) {
    my $parsed = tubular::Reader::CSV->parse($path);
    if ($parsed->{error}) {
        $result->{error} = $parsed->{error};
        return $result;
    }
    push @{ $result->{warnings} }, @{ $parsed->{warnings} };

    my $record_count = scalar @{ $parsed->{records} };
    if ($record_count == 0) {
        if ($result->{mode} eq 'text') {
            $result->{text} = '';
            $result->{ok} = 1;
        }
        else {
            $result->{values} = [];
            $result->{ok} = 1;
        }
        return $result;
    }

    # Decide whether the first record is a header.
    my $policy = $args{csv_header};
    my @records = @{ $parsed->{records} };
    my @header;
    if ($policy eq 'always') {
        @header = @{ shift @records };
    }
    elsif ($policy eq 'auto') {
        my $first = $records[0];
        my $all_text = 1;
        for my $f (@$first) {
            if (defined $f && length $f && $f =~ $NUMBER_RE) { $all_text = 0; last }
        }
        if ($all_text) {
            @header = @{ shift @records };
        }
    }

    if ($result->{mode} eq 'text') {
        my @lines = map { join ',', map { defined $_ ? $_ : '' } @$_ } @records;
        $result->{text} = join "\n", @lines;
        $result->{text} .= "\n" if @lines;
        $result->{ok} = 1;
        return $result;
    }

    my $strict = $args{strict};

    # Find which columns are all-numeric (ignoring blank cells).
    my %seen_col;
    my %numeric_ok;
    my %numeric_count;
    for my $row (@records) {
        for my $i (0 .. $#$row) {
            $seen_col{$i} = 1;
            my $cell = $row->[$i];
            if (defined $cell && length $cell) {
                if ($cell =~ $NUMBER_RE) {
                    $numeric_count{$i}++;
                }
                else {
                    $numeric_ok{$i} = 0;
                }
            }
        }
    }
    my @numeric_cols = sort { $a <=> $b } grep { !exists $numeric_ok{$_} || $numeric_ok{$_} } keys %seen_col;

    # Non-strict fallback: pick the column with the most numeric cells.
    my @best_cols = @numeric_cols;
    if (!@best_cols && !$strict && !defined $args{column} && keys %seen_col) {
        my ($best, $best_n) = (undef, -1);
        for my $c (sort { $a <=> $b } keys %seen_col) {
            if ($numeric_count{$c} > $best_n) {
                ($best, $best_n) = ($c, $numeric_count{$c});
            }
        }
        @best_cols = ($best) if defined $best;
    }

    my @cell_warnings;
    my @tokens;
    my $col;
    if (defined $args{column}) {
        $col = $class->_resolve_column($args{column}, \@header, \@numeric_cols, \@records, $result);
        return $result if $result->{error};
    }
    else {
        if (@best_cols == 0) {
            $result->{error} = "no numeric column found in $result->{source} (strict); use --strict 0 to pick the column with the most numeric values";
            return $result;
        }
        if (@best_cols > 1) {
            my @names = map { $_ <= $#header && defined $header[$_] ? $header[$_] : "$_" } @best_cols;
            my $list = join ', ', @names;
            $result->{error} = "multiple numeric columns (choose one with --column): $list";
            return $result;
        }
        $col = $best_cols[0];
    }

    my $row_i = 0;
    for my $row (@records) {
        ++$row_i;
        my $cell = $row->[$col];
        if (!defined $cell || !length $cell) {
            my $msg = "empty value in column $col, row $row_i";
            return $result->{error} = $msg if $strict;
            push @cell_warnings, $msg;
            next;
        }
        if ($cell !~ $NUMBER_RE) {
            my $msg = "column $col row $row_i: non-numeric value '$cell'";
            return $result->{error} = $msg if $strict;
            push @cell_warnings, $msg;
            next;
        }
        push @tokens, $cell;
    }

    my $seq = tubular::Sequence->from_string(join ' ', @tokens);
    $result->{column} = $col;
    $result->{header} = [ @header ];
    $result->{values} = [ $seq->values ];
    push @{ $result->{warnings} }, @cell_warnings;
    $result->{ok} = 1;
    return $result;
}

sub _resolve_column ($class, $column, $header, $numeric_cols, $records, $result) {
    if (@$header && grep { defined $_ && $_ eq $column } @$header) {
        for my $i (0 .. $#$header) {
            return $i if defined $header->[$i] && $header->[$i] eq $column;
        }
    }
    if ($column =~ /^\d+$/) {
        my $idx = 0 + $column;
        my $max_cols = 0;
        for my $row (@$records) {
            $max_cols = @$row if @$row > $max_cols;
        }
        if ($idx < $max_cols) {
            return $idx;
        }
        $result->{error} = "column index $idx out of range (0..$max_cols)";
        return undef;
    }
    $result->{error} = "unknown column '$column' (not a header name)";
    return undef;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Extract - typed input readers into sequences or text

=head1 SYNOPSIS

    use tubular::Extract;

    my $res = tubular::Extract->extract('data.csv', mode => 'numbers');
    say for @{ $res->{values} };

=head1 DESCRIPTION

Picks a reader by file extension and produces either an ordered numeric
sequence (default C<mode = 'numbers'>) or the raw extracted text
(C<mode = 'text'>).

=over 4

=item * B<text> - parsed with C<tubular::Sequence> (whitespace/commas)

=item * B<csv> - C<Text::CSV>; header auto-detection, numeric column
selection via C<column> (header name or 0-based index)

=item * B<pdf> - C<CAM::PDF::PageText>; optional C<pages> range like
C<"1-3,5">; baseline reading order is best-effort (see
C<tubular::Reader::PDF>)

=back

Result hashref: C<ok>, C<error>, C<type>, C<mode>, C<source>, C<values>,
C<text>, C<pages>, C<warnings>. C<strict> (default 1) turns any malformed
input into an error instead of a warning. Sequence ordering is always
preserved.

Falling back to strict 0 for a plain-text file with prose will quietly skip
non-numeric tokens while reporting them via C<warnings>.

=cut