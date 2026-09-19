package tubular::Reader::Text;

use v5.44;
use warnings;

use tubular::Sequence ();

our $VERSION = '0.1';

sub text ($class, $path) {
    open my $fh, '<:raw:encoding(UTF-8)', $path
        or die "tubular::Reader::Text: cannot read $path: $!\n";
    local $/;
    my $raw = <$fh> // '';
    close $fh;
    return $raw;
}

sub sequence ($class, $path, %args) {
    return tubular::Sequence->from_file($path, strict => exists $args{strict} ? $args{strict} : 1);
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Reader::Text - plain text input

=head1 DESCRIPTION

C<text> returns the raw file contents. C<sequence> parses the file as an
ordered numeric sequence via C<tubular::Sequence> (whitespace and commas
as separators). Original ordering is preserved.

=cut