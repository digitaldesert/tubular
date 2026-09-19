use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => 'tubular',
    VERSION_FROM  => 'lib/tubular/Config.pm',
    ABSTRACT      => 'Deterministic statistics and native-model forecasting toolkit',
    AUTHOR        => 'tubular developers',
    LICENSE       => 'mit',
    PREREQ_PM     => {
        'HTTP::Tiny'          => 0,
        'JSON::PP'            => 0,
        'Text::CSV'           => 0,
        'CAM::PDF'            => 0,
        'CAM::PDF::PageText'  => 0,
    },
    TEST_REQUIRES => {
        'Test::More'  => 0,
        'File::Temp'  => 0,
    },
    EXE_FILES => [
        'bin/tubular',
        'bin/doctor',
        'bin/fetch',
        'bin/extract',
        'bin/inspect',
        'bin/stats',
        'bin/models',
        'bin/forecast',
        'bin/backtest',
    ],
    MIN_PERL_VERSION => '5.44.0',
);