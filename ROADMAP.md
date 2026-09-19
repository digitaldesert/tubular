# tubular ROADMAP

Update a phase's status to DONE only after `prove -lr t` passes.

## Phase 1 — Foundation

- status: DONE (prove -lr t passes)
- goal: Project skeleton, config, sequence parsing, CLI dispatcher, doctor
- major files: AGENTS.md, ROADMAP.md, README.md, Makefile.PL, cpanfile,
  config.json, .gitignore, lib/tubular/Config.pm,
  lib/tubular/Sequence.pm, bin/tubular, bin/doctor,
  examples/sequence.txt, examples/sequence.csv, t/
- completion: config loading + override + defaults, ordered sequence
  parsing incl. strict malformed handling, tubular dispatch, doctor report

## Phase 2 — Fetch

- status: DONE (prove -lr t passes)
- goal: HTTP/HTTPS resource fetching
- major files: lib/tubular/Fetch.pm, bin/fetch
- completion: HTTP::Tiny only, temp file then atomic rename, max bytes,
  timeout, sha256, --force, --json; offline tests

## Phase 3 — Input readers

- status: DONE (prove -lr t passes)
- goal: Text/CSV/PDF extraction into sequences
- major files: lib/tubular/Extract.pm, lib/tubular/Reader/{Text,CSV,PDF}.pm,
  bin/extract
- completion: TXT/CSV/PDF fixtures and tests; --pages; -text/-numbers modes;
  PDF reading-order limitation documented

## Phase 4 — Statistics

- status: DONE (prove -lr t passes)
- goal: Deterministic inspection and statistics
- major files: lib/tubular/Stats.pm, bin/inspect, bin/stats
- completion: frequencies, empirical/recent probabilities, gaps, first/second
  order transitions, streaks; hand-verifiable tests

## Phase 5 — ZSFM adapter

- status: DONE (prove -lr t passes; adapter certified against the real
  `zsfm timesfm infer --gguf` CLI on this machine; real model inference not
  run yet — no TimesFM GGUF present, so `TUBULAR_INTEGRATION=1
  TUBULAR_ZSFM_GGUF=... prove -lr t/t/16-zsfm-integration.t` remains skipped)
- goal: Safe integration with native zsfm CLI
- major files: lib/tubular/Adapter/ZSFM.pm
- completion: locate/version/invoke zsfm, JSON in/out, timeout, mocks when
  zsfm missing; real integration gated by TUBULAR_INTEGRATION=1

## Phase 6 — Model management

- status: DONE (prove -lr t passes)
- goal: Explicit model setup/status/paths
- major files: bin/models
- completion: list/status/setup/path; no implicit downloads; q8 default dtype

## Phase 7 — Forecast

- status: DONE (prove -lr t passes)
- goal: Forecasting numeric/categorical sequences
- major files: lib/tubular/Forecast.pm, bin/forecast
- completion: modes numeric/categorical/auto, context usage reported,
  estimated probabilities labelled, no fabricated fields

## Phase 8 — Backtest

- status: DONE (prove -lr t passes)
- goal: Rolling historical evaluation
- major files: lib/tubular/Backtest.pm, bin/backtest
- completion: no look-ahead leakage (dedicated tests), baselines, MAE/RMSE,
  top-N hit rates, seedable random baseline

## Phase 9 — Ensemble

- status: DONE (prove -lr t passes)
- goal: Deterministic combination of predictors
- major files: forecast --ensemble support in lib/tubular/
- completion: backtest-weighted combining, documented formula, fallback stated

## Phase 10 — Polish and docs

- status: DONE (prove -lr t passes)
- goal: Consistent CLI, full README, hardening
- major files: README.md, all bin/*, t/
- completion: --help/--json everywhere, prove -lr t passes, smoke tests listed