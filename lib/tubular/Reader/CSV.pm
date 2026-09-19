package tubular::Reader::CSV;

use v5.44;
use warnings;

use Text::CSV ();

our $VERSION = '0.1';

# Parse a CSV file into records. Returns:
#
#   {
#     records  => [ [ field, ... ], ... ],  # every record, in file order
#     warnings => [ ... ],
#     error    => undef,
#   }
#
# Records are split only; header detection and column selection are policy
# decisions owned by tubular::Extract.
sub parse ($class, $path) {
    my $result = {
        records  => [],
        warnings => [],
        error    => undef,
    };

    open my $fh, '<:encoding(UTF-8)', $path
        or do { $result->{error} = "cannot read $path: $!\n"; return $result };

    local $/ = "\n";
    my $csv = Text::CSV->new({ binary => 1, auto_diag => 0 });

    my $row_n = 0;
    while (my $line = <$fh>) {
        ++$row_n;
        if (!$csv->parse($line)) {
            my $msg = $csv->error_diag() // 'parse failure';
            push @{ $result->{warnings} }, "row $row_n: $msg";
            next;
        }
        push @{ $result->{records} }, [ $csv->fields() ];
    }
    close $fh;

    return $result;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Reader::CSV - CSV input via Text::CSV

=head1 DESCRIPTION

Splits a CSV file into fields using C<Text::CSV> (works with the pure-Perl
backend when C<Text::CSV_XS> is absent). Every record is kept in file
order. Malformed records are skipped and reported via C<warnings> rather
than aborting the whole file.

Note: the first record is exposed as C<header> but column selection and
header auto-detection policy live in C<tubular::Extract>.

=cut