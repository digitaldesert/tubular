use v5.44;
use warnings;
use Test::More;
use File::Spec;
use File::Basename qw(dirname);
use FindBin qw($RealBin);

use lib "$RealBin/../lib";
use tubular::Extract;

my $root = dirname($RealBin);
my $fix = File::Spec->catdir($root, 't', 'fixtures');

sub fix ($name) { File::Spec->catfile($fix, $name) }

sub make_pdf (@pages_text) {
    my $n = scalar @pages_text;
    my $font_obj   = 3 + $n;             # /F1 font
    my @kids_obj   = map { 3 + $_ } 0 .. $n - 1;             # page objects
    my @stream_obj = map { 4 + $n + $_ } 0 .. $n - 1;        # content streams

    my @objs = (
        '<< /Type /Catalog /Pages 2 0 R >>',
        '<< /Type /Pages /Kids [' . join(' ', map { "$_ 0 R" } @kids_obj) . '] /Count ' . $n . ' >>',
    );
    for my $p (0 .. $n - 1) {
        push @objs,
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            . "/Resources << /Font << /F1 $font_obj 0 R >> >> /Contents $stream_obj[$p] 0 R >>";
    }
    push @objs, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>';
    for my $p (0 .. $n - 1) {
        my $stream = "BT /F1 12 Tf 72 712 Td (" . $pages_text[$p] . ") Tj ET";
        push @objs, '<< /Length ' . length($stream) . " >>\nstream\n$stream\nendstream";
    }
    my @blobs;
    for my $i (0 .. $#objs) {
        push @blobs, sprintf("%d 0 obj\n%s\nendobj\n", $i + 1, $objs[$i]);
    }
    my @offsets = (0) x scalar(@blobs);
    my $pdf = "%PDF-1.4\n";
    for my $i (0 .. $#blobs) {
        $offsets[$i] = length $pdf;
        $pdf .= $blobs[$i];
    }
    my $xref_start = length $pdf;
    $pdf .= 'xref' . "\n0 " . (scalar(@blobs) + 1) . "\n";
    $pdf .= "0000000000 65535 f \n";
    for my $off (@offsets) {
        $pdf .= sprintf("%010d 00000 n \n", $off);
    }
    $pdf .= 'trailer' . "\n<< /Size " . (scalar(@blobs) + 1) . " /Root 1 0 R >>\nstartxref\n$xref_start\n%%EOF\n";
    return $pdf;
}

sub make_pdf_file ($path, @pages_text) {
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} make_pdf(@pages_text);
    close $fh;
}

subtest 'plain text -> numbers' => sub {
    my $res = tubular::Extract->extract(fix('numbers.txt'));
    ok($res->{ok}, 'ok');
    is_deeply($res->{values}, [ 3, 1, 4, 1, 5, 9, 2 ], 'values in order');
    is($res->{type}, 'text', 'type text');
    is($res->{mode}, 'numbers', 'default mode numbers');
};

subtest 'plain text -> text' => sub {
    my $res = tubular::Extract->extract(fix('numbers.txt'), mode => 'text');
    ok($res->{ok}, 'ok');
    like($res->{text}, qr/9 2/, 'raw text returned');
};

subtest 'strict rejects malformed text' => sub {
    my $res = tubular::Extract->extract(fix('bad.txt'));
    ok(!$res->{ok}, 'strict fails');
    like($res->{error}, qr/xyz/, 'error names the token');
};

subtest 'non-strict skips malformed text with warning' => sub {
    my $res = tubular::Extract->extract(fix('bad.txt'), strict => 0);
    ok($res->{ok}, 'ok');
    is_deeply($res->{values}, [ 10, 20, 30 ], 'numeric tokens kept in order');
    is(scalar @{ $res->{warnings} }, 1, 'one warning');
    like($res->{warnings}[0], qr/xyz/, 'warning names token');
};

subtest 'csv auto header + sole numeric column' => sub {
    my $res = tubular::Extract->extract(fix('multi.csv'));
    ok($res->{ok}, 'ok');
    is_deeply($res->{values}, [ 4, 8, 15 ], 'value column picked');
    is($res->{column}, 1, 'column index 1');
    is_deeply($res->{header}, [ 'date', 'value', 'label' ], 'header captured');
};

subtest 'csv --column by name and index' => sub {
    my $res = tubular::Extract->extract(fix('multi.csv'), column => 'value');
    ok($res->{ok}, 'ok');
    is_deeply($res->{values}, [ 4, 8, 15 ], 'value column by name');

    $res = tubular::Extract->extract(fix('multi.csv'), column => 1);
    ok($res->{ok}, 'ok');
    is_deeply($res->{values}, [ 4, 8, 15 ], 'value column by index');
};

subtest 'csv multiple numeric columns need --column' => sub {
    my $res = tubular::Extract->extract(fix('two_numeric.csv'));
    ok(!$res->{ok}, 'refuses when ambiguous');
    like($res->{error}, qr/--column/, 'error suggests --column');
    $res = tubular::Extract->extract(fix('two_numeric.csv'), column => 1);
    ok($res->{ok}, 'column 1 chosen');
    is_deeply($res->{values}, [ 2, 4 ], 'second column extracted');
};

subtest 'csv no numeric column' => sub {
    my $res = tubular::Extract->extract(fix('non_numeric.csv'));
    ok(!$res->{ok}, 'fails');
    like($res->{error}, qr/no numeric column/, 'error explains');
};

subtest 'csv unknown column errors' => sub {
    my $res = tubular::Extract->extract(fix('multi.csv'), column => 'nope');
    ok(!$res->{ok}, 'unknown name fails');
    $res = tubular::Extract->extract(fix('multi.csv'), column => 12);
    ok(!$res->{ok}, 'out-of-range index fails');
};

subtest 'csv header never treats first row as data' => sub {
    my $res = tubular::Extract->extract(fix('simple.csv'), csv_header => 'never');
    ok(!$res->{ok}, 'strict fails with no clean numeric column');
    like($res->{error}, qr/no numeric column/, 'error explains');

    $res = tubular::Extract->extract(fix('simple.csv'), csv_header => 'never', strict => 0);
    ok($res->{ok}, 'non-strict picks column with most numeric values');
    is_deeply($res->{values}, [ 4, 8, 15, 16 ], 'header row skipped with warning');
    is(scalar @{ $res->{warnings} }, 1, 'one warning');
};

subtest 'csv text mode reconstructs records' => sub {
    my $res = tubular::Extract->extract(fix('multi.csv'), mode => 'text');
    ok($res->{ok}, 'ok');
    like($res->{text}, qr/^2024-01-01,4,a/m, 'first data row');
    like($res->{text}, qr/3,15,c\n\z/, 'last data row');
};

subtest 'pdf numbers with optional pages' => sub {
    my $dir = File::Spec->catdir($root, 't', 'tmp');
    mkdir $dir unless -d $dir;
    my $pdf = File::Spec->catfile($dir, 'two.pdf');
    make_pdf_file($pdf, '1 2 3', '4 5');

    my $res = tubular::Extract->extract($pdf);
    ok($res->{ok}, 'all pages ok');
    is_deeply($res->{values}, [ 1, 2, 3, 4, 5 ], 'all pages in order');
    is_deeply($res->{pages}, [ 1, 2 ], 'pages recorded');

    $res = tubular::Extract->extract($pdf, pages => '2');
    ok($res->{ok}, 'single page ok');
    is_deeply($res->{values}, [ 4, 5 ], 'only page 2');

    $res = tubular::Extract->extract($pdf, pages => '1-3');
    ok($res->{ok}, 'range ok');
    is_deeply($res->{values}, [ 1, 2, 3, 4, 5 ], 'range clamped to doc');

    $res = tubular::Extract->extract($pdf, pages => '1-3,5');
    ok($res->{ok}, 'mixed list ok');
    is_deeply($res->{values}, [ 1, 2, 3, 4, 5 ], 'out-of-range pages skipped');
    ok(scalar @{ $res->{warnings} }, 'out-of-range warned');
};

subtest 'pdf invalid range errors' => sub {
    my $dir = File::Spec->catdir($root, 't', 'tmp');
    my $pdf = File::Spec->catfile($dir, 'two.pdf');
    my $res = tubular::Extract->extract($pdf, pages => 'abc');
    ok(!$res->{ok}, 'garbage range fails');
    like($res->{error}, qr/page range/, 'error explains');
};

subtest 'pdf text mode' => sub {
    my $dir = File::Spec->catdir($root, 't', 'tmp');
    my $pdf = File::Spec->catfile($dir, 'two.pdf');
    my $res = tubular::Extract->extract($pdf, mode => 'text', pages => '2');
    ok($res->{ok}, 'ok');
    like($res->{text}, qr/4 5/, 'page text extracted');
};

subtest 'type gating' => sub {
    my $res = tubular::Extract->extract(fix('numbers.txt'), pages => '1');
    ok(!$res->{ok}, 'pages on txt rejected');
    like($res->{error}, qr/only valid for PDF/, 'error explains');

    my $dir = File::Spec->catdir($root, 't', 'tmp');
    mkdir $dir unless -d $dir;
    my $weird = File::Spec->catfile($dir, 'data.xyz');
    open my $fh, '>', $weird or die $!;
    print {$fh} "1 2 3\n";
    close $fh;
    $res = tubular::Extract->extract($weird);
    ok(!$res->{ok}, 'unknown extension rejected');
    like($res->{error}, qr/unsupported file type/, 'error names extension');
};

done_testing;