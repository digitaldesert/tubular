package tubular::Config;

use v5.44;
use warnings;

use JSON::PP ();
use File::Spec ();
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Scalar::Util qw(reftype looks_like_number);

our $VERSION = '0.1';

my %BUILTIN_DEFAULTS = (
    home => '.tubular',
    fetch => {
        timeout    => 30,
        max_bytes  => 52_428_800,
        user_agent => 'tubular/0.1',
    },
    input => {
        strict     => 1,
        csv_header => 'auto',
    },
    models => {
        max_bytes => 21_474_836_480,    # 20 GiB, model downloads
    },
    image => {
        base_url => 'http://127.0.0.1:20128/v1',    # OmniRoute OpenAI-compatible base
        timeout  => 300,                             # seconds (300000 ms effective)
    },
    forecast => {
        runner            => 'zsfm',
        model             => 'timesfm',
        dtype             => 'q8',
        gguf              => '',
        zsfm_path         => '',
        timeout           => 120,
        horizon           => 1,
        top               => 2,
        mode              => 'auto',
        backtest_windows  => 1000,
    },
);

sub new ($class, %args) {
    my $self = bless {}, $class;

    my $root = $self->project_root;

    my $config_path;
    if (defined $args{config_path}) {
        $config_path = File::Spec->rel2abs($args{config_path});
        die "tubular::Config: config file not found: $config_path\n"
            unless -e $config_path;
    }
    elsif (defined $ENV{TUBULAR_CONFIG} && length $ENV{TUBULAR_CONFIG}) {
        $config_path = File::Spec->rel2abs($ENV{TUBULAR_CONFIG});
        die "tubular::Config: TUBULAR_CONFIG file not found: $config_path\n"
            unless -e $config_path;
    }
    elsif (-e File::Spec->catfile($root, 'config.json')) {
        $config_path = File::Spec->catfile($root, 'config.json');
    }
    elsif (-e File::Spec->catfile(File::Spec->curdir, 'config.json')) {
        $config_path = File::Spec->catfile(File::Spec->canonpath(File::Spec->curdir), 'config.json');
    }

    $self->{file}   = $config_path;
    $self->{root}   = $root;
    $self->{loaded} = 0;

    my $data = {};
    if (defined $config_path) {
        my $json = $self->_read_json($config_path);
        die "tubular::Config: $config_path must contain a JSON object\n"
            unless reftype($json) && reftype($json) eq 'HASH';
        $data = $json;
        $self->{loaded} = 1;
    }

    if (defined $args{overrides} && reftype($args{overrides}) eq 'HASH') {
        $data = _deep_merge($data, $args{overrides});
    }

    $self->_validate_basic($data);

    $self->{data} = _deep_merge({ %BUILTIN_DEFAULTS }, $data);

    $self->{home_opt} = defined $args{home} ? $args{home} : undef;

    return $self;
}

sub _read_json ($self, $path) {
    open my $fh, '<:raw:encoding(UTF-8)', $path
        or die "tubular::Config: cannot read $path: $!\n";
    local $/;
    my $raw = <$fh> // '';
    $raw =~ s/^\x{FEFF}//;
    my $json = eval { JSON::PP::decode_json($raw) };
    die "tubular::Config: invalid JSON in $path: $@\n" if $@;
    return $json;
}

sub _validate_basic ($self, $data) {
    return if $self->{_validated}++;
    my @bad;
    for my $key (qw(home)) {
        push @bad, "$key must be a plain string"
            if exists $data->{$key} && defined $data->{$key} && ref $data->{$key};
    }
    for my $group (qw(fetch input models forecast image)) {
        next unless defined $data->{$group};
        push @bad, "$group must be an object"
            if ref($data->{$group}) ne 'HASH';
    }
    if (ref $data->{models} eq 'HASH') {
        $self->_check_num(\@bad, 'models.max_bytes', $data->{models}{max_bytes});
    }
    if (ref $data->{fetch} eq 'HASH') {
        $self->_check_num(\@bad, 'fetch.timeout', $data->{fetch}{timeout});
        $self->_check_num(\@bad, 'fetch.max_bytes', $data->{fetch}{max_bytes});
        push @bad, 'fetch.user_agent must be a plain string'
            if defined $data->{fetch}{user_agent} && ref $data->{fetch}{user_agent};
    }
    if (ref $data->{input} eq 'HASH') {
        if (exists $data->{input}{strict}) {
            my $s = "$data->{input}{strict}";
            push @bad, 'input.strict must be a boolean'
                unless grep { $_ eq $s } (1, 0, 'true', 'false', 'yes', 'no');
        }
    }
    if (ref $data->{image} eq 'HASH') {
        $self->_check_num(\@bad, 'image.timeout', $data->{image}{timeout});
        push @bad, 'image.base_url must be a plain string'
            if defined $data->{image}{base_url} && ref $data->{image}{base_url};
    }
    if (ref $data->{forecast} eq 'HASH') {
        for my $k (qw(horizon top backtest_windows timeout)) {
            $self->_check_num(\@bad, "forecast.$k", $data->{forecast}{$k});
        }
        for my $k (qw(runner model dtype mode gguf zsfm_path)) {
            push @bad, "forecast.$k must be a plain string"
                if defined $data->{forecast}{$k} && ref $data->{forecast}{$k};
        }
    }
    die "tubular::Config: invalid configuration: " . join('; ', @bad) . "\n"
        if @bad;
    return;
}

sub _check_num ($self, $bad, $path, $value) {
    return unless defined $value;
    push @$bad, "$path must be numeric" unless looks_like_number($value);
}

sub _deep_merge ($base, $over) {
    return $base unless defined $over;
    my $out = { %$base };
    for my $k (sort keys %$over) {
        if (ref($over->{$k}) eq 'HASH'
            && ref($out->{$k}) eq 'HASH') {
            $out->{$k} = _deep_merge($out->{$k}, $over->{$k});
        }
        else {
            $out->{$k} = $over->{$k};
        }
    }
    return $out;
}

sub project_root ($self) {
    return $self->{root} if defined $self->{root};
    my $file = abs_path(__FILE__) || File::Spec->rel2abs(__FILE__);
    my $dir = dirname($file);    # lib/tubular
    $dir = dirname($dir);        # lib
    $dir = dirname($dir);        # project root
    $self->{root} = $dir;
    return $self->{root};
}

sub config_path ($self) {
    return $self->{file};
}

sub config_loaded ($self) {
    return $self->{loaded};
}

sub is_default ($self) {
    return 1 unless defined $self->{file};
    return 0;
}

sub home ($self) {
    return $self->{home} if defined $self->{home};
    my $h = $self->{home_opt};
    $h = $ENV{TUBULAR_HOME} if !defined $h && defined $ENV{TUBULAR_HOME} && length $ENV{TUBULAR_HOME};
    if (defined $h && length $h) {
        $self->{home} = File::Spec->rel2abs($h);
    }
    else {
        my $rel = defined $self->get('home') ? $self->get('home') : '.tubular';
        $self->{home} = File::Spec->rel2abs($rel, $self->project_root);
    }
    return $self->{home};
}

sub resolve ($self, $path) {
    return File::Spec->rel2abs($path, File::Spec->rel2abs($self->project_root));
}

sub get ($self, @keys) {
    my $cur = $self->{data};
    for my $k (@keys) {
        return undef unless ref $cur eq 'HASH' && exists $cur->{$k};
        $cur = $cur->{$k};
    }
    return $cur;
}

sub as_hash ($self) {
    return $self->{data};
}

sub override ($self, %overrides) {
    my %patch;
    for my $key (keys %overrides) {
        if (index($key, '.') >= 0) {
            my $p = _dotted_patch($key, $overrides{$key});
            %patch = (%patch, %$p);
        }
        else {
            $patch{$key} = $overrides{$key};
        }
    }
    $self->{data} = _deep_merge($self->{data}, \%patch);
    return $self;
}

sub _dotted_patch ($key, $value) {
    my @parts = split /\./, $key;
    my $out = {};
    my $cur = $out;
    for my $i (0 .. $#parts) {
        if ($i == $#parts) {
            $cur->{ $parts[$i] } = $value;
        }
        else {
            $cur->{ $parts[$i] } = {};
            $cur = $cur->{ $parts[$i] };
        }
    }
    return $out;
}

sub version ($self) {
    return $VERSION;
}

1;

__END__

=encoding utf8

=head1 NAME

tubular::Config - project configuration for tubular

=head1 SYNOPSIS

    use tubular::Config;

    my $config = tubular::Config->new();

    my $model = $config->get('forecast', 'model');
    my $home  = $config->home;

=head1 DESCRIPTION

Locates and loads the root C<config.json>, merges it over built-in emergency
defaults, validates the basic structure, and exposes the merged configuration.
CLI-level overrides can be applied later via C<override()>.

Lookup order for the config file:

=over 4

=item 1.

Explicit C<< config_path => ... >> constructor argument.

=item 2.

The C<TUBULAR_CONFIG> environment variable.

=item 3.

C<config.json> in the project root (derived from this module's location).

=item 4.

C<config.json> in the current working directory.

=back

If no config file exists, built-in defaults are used and
C<config_loaded()> returns false.

=cut