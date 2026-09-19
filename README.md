# tubular

tubular is a Perl 5.44+ command-line toolkit for:

- fetching specific remote resources
- reading numerical data from text, CSV and PDF files
- normalizing ordered numerical sequences
- inspecting and statistically analysing sequences
- forecasting future values with deterministic methods
- combining forecasts into a backtest-weighted ensemble
- backtesting forecasting methods
- comparing deterministic statistical methods with forecasting models

This is **not** an LLM/chat application. Forecasting inference is performed by
the external native `zsfm` executable; every statistical calculation is
deterministic Perl.

## Requirements

- Perl **5.44 or newer**
- CPAN modules declared in `cpanfile` (see below)
- `zsfm` (external executable) only for forecasting; absent is fine for all
  deterministic features

## Installing CPAN dependencies

With `cpanminus`:

```
cpanm --installdeps .
```

or through the bundled dist config:

```
perl Makefile.PL
make
make test
```

Key dependencies:

- **Text::CSV** — CSV parsing; stays usable without `Text::CSV_XS`
  (pure-Perl fallback). No compiler required.
- **CAM::PDF / CAM::PDF::PageText** — Perl-native PDF text extraction.
  Extraction only works when the PDF contains embedded usable text; no OCR is
  included.
- **HTTP::Tiny** — all HTTP retrieval.
- **JSON::PP** — safe JSON encoding/decoding.

## Configuration

Root `config.json` holds the project defaults. CLI options override the
config; the config overrides built-in emergency defaults.

- `TUBULAR_CONFIG` — path to an alternative config file.
- `TUBULAR_HOME` — runtime directory override (default `.tubular/`, with
  `cache/`, `downloads/`, `models/`, `tmp/` subdirectories).

## The `zsfm` executable

`zsfm` is a native forecasting CLI used for model inference only. There are
three separate things to install: **zsfm**, a **model**, and then the
tubular run itself.

### Installing zsfm

```
cargo install zsfm --locked
```

Verify with:

```
zsfm --help
```

The installed zsfm implements a subcommand CLI such as
`zsfm timesfm infer` and provides no `--version` flag (tubular detects this
and identifies the binary via `--help`). `bin/doctor` and
`bin/models status` report the resolved path and helpers such as
`zsfm path: ...`, `timesfm: supported`.

Prebuilt `zsfm` binaries may be published for supported platforms; if no
prebuilt binary is available for your platform (for example Intel macOS),
building with Cargo is the supported path. See the upstream zsfm
documentation for current platform-specific details.

### Installing a model

Model files are downloaded/converted explicitly via `bin/models setup`
(see ROADMAP Phase 6). No model is downloaded implicitly — neither by
zsfm nor by tubular:

```
bin/models setup timesfm --file /path/to/timesfm.gguf
```

or, for an explicit conversion-style install, the upstream GGUF produced
by `zsfm timesfm convert`. The default dtype is `q8`
(config `forecast.dtype`). `bin/models status` reports whether the runtime
and a model are present.

### Running forecasting

With zsfm and a GGUF model in place, inference runs as a single process
with a JSON request on stdin and a JSON forecast on stdout:

```
zsfm timesfm infer --gguf /abs/path/to/model.gguf
```

```
{"context": [1, 2, 3], "horizon": 1}
```

The native output is normalised inside `tubular::Adapter::ZSFM` (the only
place that understands raw zsfm JSON) into a stable shape
`{ model, point, quantiles, raw_model }`.

Environment variables used at the adapter boundary:

- `TUBULAR_ZSFM` — path to the zsfm executable (override of PATH search).
- `TUBULAR_INTEGRATION` — set to `1` to allow real native inference; the
  adapter otherwise refuses so unit tests can mock the boundary.
- `TUBULAR_ZSFM_GGUF` — TimesFM GGUF path used by the optional integration
  test (config `forecast.gguf` is the fallback source for that path).

tubular itself does NOT require Python, and zsfm native inference does NOT
require Python or PyTorch. Model files remain governed by their own licenses.

## Usage

```
bin/tubular fetch URL
bin/tubular extract source.csv
bin/tubular inspect numbers.txt
bin/tubular stats numbers.txt
bin/tubular forecast numbers.txt
bin/tubular forecast --ensemble numbers.txt
bin/tubular backtest numbers.txt
bin/tubular models list
bin/doctor
```

Standalone commands behave identically, e.g. `bin/forecast numbers.txt`.

Every command supports `--help`; data commands support `--json`.

### Forecast

`bin/forecast` produces deterministic, purely empirical forecasts (last
value, mean, first-order Markov on the context, empirical histogram).
`--mode auto` picks the categorical branch for at most 12 distinct values
and the numeric branch otherwise:

```
bin/forecast --values "3 1 4 1 5 9 2"
bin/forecast --mode categorical --horizon 3 --top 5 numbers.txt
```

`--ensemble` combines the deterministic methods with weights derived from a
rolling backtest of the same input, `w = 1/(1+mae)` per method (see
`tubular::Forecast` for the documented formula):

```
bin/forecast --ensemble --horizon 2 --top 3 numbers.txt
```

### Backtest

`bin/backtest` scores each method on a rolling window with no look-ahead
(the train slice always ends just before the scored value) and reports
MAE, RMSE and top-N hit rate:

```
bin/backtest --window 50 --min-train 10 numbers.txt
```

STDOUT carries successful output/data; warnings and errors go to STDERR.
Failures exit with a non-zero status.

## Testing

Run the full suite from the repository root:

```
prove -lr t
```

The optional `TUBULAR_INTEGRATION=1` environment variable switches on tests
that invoke a real external `zsfm`; without it those tests are skipped so
the whole suite passes offline. Real model inference additionally needs a
TimesFM GGUF, supplied through `TUBULAR_ZSFM_GGUF` (or config
`forecast.gguf`):

```
TUBULAR_INTEGRATION=1 TUBULAR_ZSFM_GGUF=/abs/path/to/model.gguf prove -lr t/t/16-zsfm-integration.t
```

The integration test asserts plumbing only (process success, valid JSON,
normalized response, horizon length) — never a specific forecast value.

## Scientific limitation

tubular can identify statistical structure and evaluate forecasting methods
against historical data. It cannot make a truly independent random process
predictable.

Historical patterns may be:

- genuine structure
- temporary effects
- sampling noise
- overfitting

Backtesting is therefore a core tubular feature, not an optional marketing
demonstration.

## License

MIT, see LICENSE.md.