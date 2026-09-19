package tubular::Reader::PDF;

use v5.44;
use warnings;

use CAM::PDF ();
use CAM::PDF::PageText ();

our $VERSION = '0.1';

# Parse a page range like "1-3,5" into a sorted list of page numbers.
# Returns a hashref { pages, error } where error is set on malformed input.
sub parse_range ($class, $range) {
    my $bad = 0;
    my @pages;
    for my $part (split /\s*,\s*/, $range) {
        if ($part =~ /\A(\d+)\s*-\s*(\d+)\z/) {
            my ($a, $b) = ($1, $2);
            ($a, $b) = ($b, $a) if $a > $b;
            push @pages, $a .. $b;
        }
        elsif ($part =~ /\A(\d+)\z/) {
            push @pages, $1;
        }
        else {
            $bad = 1;
        }
    }
    return {
        pages => \@pages,
        error => $bad ? "invalid page range '$range' (expected e.g. 1-3,5)" : undef,
    };
}

# Extract text from the given pages (1-based) of a PDF.
# Returns { text, pages, warnings, error }.
sub pages ($class, $path, %args) {
    my $result = { text => '', pages => [], warnings => [], error => undef };

    my $range = $args{pages};
    my @wanted;
    if (defined $range && length $range) {
        my $r = $class->parse_range($range);
        if ($r->{error}) {
            $result->{error} = $r->{error};
            return $result;
        }
        @wanted = @{ $r->{pages} };
    }
    else {
        @wanted = ();
    }

    my $pdf;
    eval {
        $pdf = CAM::PDF->new($path);
    };
    if ($@ || !$pdf) {
        $result->{error} = "cannot open PDF $path: $@";
        return $result;
    }

    my $num_pages = eval { $pdf->numPages() };
    if (!$num_pages) {
        $result->{error} = "cannot determine page count for $path";
        return $result;
    }

    @wanted = 1 .. $num_pages unless @wanted;

    for my $page_no (@wanted) {
        if ($page_no < 1 || $page_no > $num_pages) {
            push @{ $result->{warnings} }, "page $page_no out of range (1..$num_pages), skipped";
            next;
        }
        my $text = '';
        eval {
            my $tree = $pdf->getPageContentTree($page_no);
            $text = CAM::PDF::PageText->render($tree) // '';
        };
        if ($@) {
            push @{ $result->{warnings} }, "page $page_no: text extraction failed: $@";
            next;
        }
        push @{ $result->{pages} }, $page_no;
        $result->{text} .= $text;
    }

    return $result;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Reader::PDF - PDF page text extraction

=head1 DESCRIPTION

Extracts text from a PDF using C<CAM::PDF> and C<CAM::PDF::PageText>.
Page numbers are 1-based. A single C<pages> argument selects either a
concrete list (C<"1,3">) or a range (C<"1-3,5">); omitted pages mean the
whole document, which is the default.

=head2 Reading order limitation

PDF stores text as a graphical layout in arbitrary drawing order.
C<CAM::PDF::PageText> applies heuristics to guess reading order and can be
fooled by non-horizontal text, multi-column layouts, subscripts and form
fields. Extracted text is therefore best-effort: downstream sequence parsing
should be reviewed against the source document. This is a documented
limitation, not a bug.

=cut