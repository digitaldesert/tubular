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
bin/tubular image --model MODEL --prompt "PROMPT"
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

## Image generation

`bin/image` generates images two ways:

- `aihorde/*` and `horde/*` models call the **AI Horde** native async API
  (`POST /api/v2/generate/async`) through `tubular::Adapter::Horde`. Set
  `AI_HORDE_API_KEY` for queue priority; otherwise Horde's documented
  anonymous key is used. Keys are never printed.
- Every other model goes through the **OmniRoute** OpenAI-compatible
  endpoint (`POST /v1/images/generations`) and requires `OMNIROUTE_API_KEY`.

```
bin/image \
    --model aihorde/Flux.1-Schnell\ fp8\ \(Compact\) \
    --prompt "A watercolor painting of Ottawa in autumn"
```

A prompt can also be piped via STDIN; `--prompt` always wins over a piped
prompt:

```
echo "A cinematic moonlit forest" | bin/image \
    --model aihorde/SDXL\ 1.0 \
    --size 1024x1024 \
    --output forest.png
```

Useful options: `--output FILE` (default `image-YYYYMMDD-HHMMSS.png`),
`--size 1024x1024` (or `--width W --height H`), `--n N`, `--format
png|jpg|jpeg|webp`, `--quality low|medium|high`, `--negative-prompt TEXT`,
`--seed N`, `--timeout N` (seconds, default configurable via `image.timeout`,
300 s = 300000 ms effective) and `--force` to overwrite existing files.
For `aihorde/*` models, `--nsfw` / `--no-nsfw` and `--censor-nsfw` /
`--no-censor-nsfw` control Horde request classification (default SFW:
`nsfw=false`, `censor_nsfw=true`, sent explicitly). OmniRoute is not in
that path; `--base-url` is OmniRoute-only, `--horde-base-url` points at
the Horde API (default from config `image.horde_base_url`).

### Queues, wait times and providers

`aihorde/*` models generate through the AI Horde queue: every job is queued
and served when a worker is free, so a request can take minutes (raise
`--timeout` accordingly). `bin/image` is queue-aware:

- when Horde reports a wait time or queue position, the values are printed
  after a successful generation and included in `--json` output as
  `wait_time` and `queue_position`;
- if no worker can fulfill the job, `bin/image` fails with a
  worker-unavailable error and a hint that this is a queue wait;
- if a worker censors the result because the request was classified as SFW,
  `bin/image` fails instead of writing the black placeholder image, with:
  "AI Horde worker censored the generated image because this request was
  classified as SFW."

Use `--json` for machine-readable output; it reports `ok`, `model`, `prompt`,
`base_url`, `requested_n`, per-image `file`/`bytes`/`ext`/`source`/`url`, and
the optional `wait_time`/`queue_position` fields.
`--n N` writes numbered output files such as `squirrel-001.png`. Responses
carrying either base64 image data or an image URL are both handled. See
`bin/image --help` and `tubular::Image` for full details. Never run image
generation in the offline test suite.

The OmniRoute base URL and timeout come from config `image.base_url` and
`image.timeout` (defaults `http://127.0.0.1:20128/v1` and 300). The Horde
API base is `image.horde_base_url` (default `https://aihorde.net/api`).

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