# AGENTS.md

Condensed permanent engineering rules for tubular. Read before coding.
Future OpenCode/free-model sessions rely on this file.

## Project facts

- Project: **tubular** — a Perl CLI toolkit for fetching resources,
  extracting numerical sequences, computing deterministic statistics, and
  forecasting via the external `zsfm` native executable.
- Main executable: `bin/tubular` (subcommand dispatcher). Standalone
  `bin/*` scripts are thin wrappers with identical behaviour.
- Target Perl: **5.44+**. Scripts start with `#!/usr/bin/env perl` and
  use `use v5.44; use warnings;`.
- Root `config.json` is the authoritative source of defaults. CLI overrides
  config; config overrides emergency built-in defaults.
- Dependencies are declared in `cpanfile` (and `Makefile.PL`).

## Hard rules

- Perl only. **No Python, no PyTorch** as runtime dependencies.
- HTTP retrieval ONLY through `HTTP::Tiny`. Never curl/wget/LWP/Mojo.
- CSV through `Text::CSV` (must stay usable without `Text::CSV_XS`).
- PDF text extraction through `CAM::PDF` / `CAM::PDF::PageText`.
- `zsfm` is an external native CLI, invoked ONLY through
  `tubular::Adapter::ZSFM` (later phase). Never via shell.
- Deterministic math (statistics, frequencies, Markov, gaps, backtesting)
  stays in Perl. Never use an LLM to count/analyse sequence values.
- Preserve sequence order. Never silently sort input.
- Never shell-interpolate URLs, filenames, paths, numbers, model names or
  GGUF paths. Use list-form process invocation.
- Reusable logic belongs in `lib/tubular/`. Scripts in `bin/` stay thin.
- Tests are required; run `prove -lr t`.
- Never claim a test was run if it was not.
- If an external program is missing, mock the boundary for unit tests and
  report that real integration was not run.
- Don't silently change CLI semantics or output contracts.
- Don't implement future ROADMAP phases without explicit instruction.
- Work on one phase only. The existing repository is authoritative.

## Phase status

See `ROADMAP.md`. Update a phase's status only after `prove -lr t` passes.