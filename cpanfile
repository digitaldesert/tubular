requires 'perl', '5.44.0';

requires 'HTTP::Tiny';          # HTTP retrieval (core since 5.14)
requires 'JSON::PP';            # safe JSON decode/encode (core)
requires 'Text::CSV';           # CSV parsing, pure-Perl fallback without XS
requires 'CAM::PDF';            # Perl-native PDF text extraction
requires 'CAM::PDF::PageText';

on 'test' => sub {
    requires 'Test::More';
    requires 'File::Temp';
};