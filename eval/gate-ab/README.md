# eval/gate-ab — Gate A/B Evaluation Harness

## Purpose

A/B evaluation framework to measure whether a code-gate helps a headless Claude agent complete skreeep2 tasks. See the gate-evaluation design spec: `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-03-gate-evaluation-design.md`.

## File Structure

```
eval/gate-ab/
  README.md                 what this is, how to run, where results go
  lib.sh                    paths, constants, helpers sourced by every script
  timeout.py                run a command with a wall-clock limit, kill its process group
  prepare.sh                <task>: build ~/gate-eval/base/<task>/ (cut tree, hidden spec, validation record)
  warm-cache.sh             build the HEAD reference tree ~/gate-eval/head/ (own out dir)
  run.sh                    <task> <arm> <rep>: one run, collect artefacts
  score.py                  <run-dir>: score.json
  report.py                 <runs-root>: results.csv + summary.md
  campaign.sh               [--smoke]: all runs in order, resumable
  tasks/<task>/task.env     TASK_MODULE, HIDDEN_SPEC, CUT_FILES, FEATURE
  tasks/<task>/prompt.txt   the prompt (same both arms)
  tasks/<task>/stub/<path>  replacement source for each cut file
  tests/test_score.py       unittest for score.py
  tests/test_report.py      unittest for report.py
  tests/shell-test.sh       sh/dash tests for lib.sh, timeout.py, run.sh (fake claude), campaign.sh
  tests/fixtures/...        transcripts and fake trees
```

## Workflow

### 1. Build the HEAD reference tree (one-time)

```bash
sh eval/gate-ab/warm-cache.sh
```

Compiles HEAD once; later steps compile their own trees cold.

### 2. Prepare each task

```bash
sh eval/gate-ab/prepare.sh noise
sh eval/gate-ab/prepare.sh mixer-modes
sh eval/gate-ab/prepare.sh mcu
sh eval/gate-ab/prepare.sh note-ring
sh eval/gate-ab/prepare.sh backpressure
sh eval/gate-ab/prepare.sh scope-view
sh eval/gate-ab/prepare.sh modes
sh eval/gate-ab/prepare.sh midi-synth
```

Each task needs preparation (e.g., environment setup).

### 3. Smoke test

```bash
sh eval/gate-ab/campaign.sh --smoke
```

Verify setup with a minimal run (useful for debugging before full campaign).

### 4. Run the full campaign

```bash
sh eval/gate-ab/campaign.sh
```

Execute the A/B evaluation across all tasks and replications.

### 5. Generate reports

```bash
python3 eval/gate-ab/report.py ~/gate-eval/runs
```

Analyze results and produce summary.

## Results

Each run lives at `~/gate-eval/runs/<task>-<arm>-<rep>/`, e.g. `noise-g-1`, `noise-u-1`:

```
~/gate-eval/runs/<task>-<arm>-<rep>/
  repo/                one-off clone of skreeep2 at GA_COMMIT
  holdout/             gated only — skreeep2-holdout at GA_HOLDOUT_COMMIT
  prompt.txt           the prompt sent to Claude
  settings.json        Claude API settings (model, temperature, etc.)
  transcript.jsonl     raw Claude conversation (one message per line)
  run.json             metadata (task, arm, rep, elapsed, tokens, status)
  final.diff           output diff between base and final code
  final-tree.tar.gz    tarred final source tree
  score.json           evaluation result
```

Plus:
- `~/gate-eval/campaign.log` — campaign execution log
- `~/gate-eval/base/<task>/` — base tree per task (cut tree, hidden spec, validation record)
- `~/gate-eval/head/` — full HEAD reference tree with its own compiled `out`
- `~/gate-eval/runs/results.csv` — aggregated results from report.py
- `~/gate-eval/runs/summary.md` — human-readable summary from report.py

- `~/gate-eval/head-baseline.json` — per-module pass/fail of HEAD, written by `python3 eval/gate-ab/score.py --baseline` (run once, while head is readable, before the first run; fails loudly on an empty module list, a resolve failure, a timeout or a non-test failure). Scoring a run without it records `error="no baseline"`.

## score.json notes

- Hidden score runs only the hidden spec's suite (`<TASK_MODULE>.testOnly <package>.<Object>`). The module's other suites, and every other test module, run in one `-k -j 1` Mill invocation (cap `GA_REGRESS_CAP`, default 1200 s) and count as regressions; failures are attributed per module from `[error] <module>.testForked` lines.
- `score_timeouts`: steps that hit the Mill cap during scoring (`<TASK_MODULE>`, `holdout.test`, `regressions`); a timeout counts as FAIL.
- `build_edits`: `*.mill` files the agent edited (suspects, reported only; not part of `solved`).
- `error`: `"scoring incomplete"` in a partial record (scoring died or still running); `"mill failed: ..."` for Mill failures without test output; `"hidden suite did not run"`; `"no baseline"`.
- Contamination detection is token-based: it resolves path-like tokens against `<run>/repo` and does not follow `cd` chains, variables or subshells, so a multi-`cd` command can evade it. It is a tripwire, not a sandbox (run.sh's mode-000 locking is the enforcement).

## Crash recovery

While an agent runs, run.sh makes `~/gate-eval/base`, `~/gate-eval/head` and the other run dirs mode 000 (agent isolation) and restores them on exit, including on INT/TERM. After a hard crash (kill -9, power loss) they may stay locked: run `. eval/gate-ab/lib.sh; ga_unlock_all` (campaign.sh does this at start).

## Testing

```bash
# Test under sh
sh eval/gate-ab/tests/shell-test.sh

# Test under dash
SH=dash dash eval/gate-ab/tests/shell-test.sh
```

Expected: 9 passed, 0 failed (both shells).

## Preparing the cache and tasks

`sh warm-cache.sh` once (builds the HEAD reference tree, about 1 min), then `sh prepare.sh <task>` per task (about 1 min each; `noise` takes about 11 min because its hidden spec hangs on the stub, see below). Mill selectors used: `__.compile` and `__.test.compile` (both valid in skreeep2 at 6bf6c1b).

- Mill records absolute paths in its output, so an `out` directory is never copied: a copy writes into the original's classes and would leak one run's compiled solution into the next. warm-cache.sh only builds the HEAD reference tree `~/gate-eval/head` (its own `out`); every other tree compiles cold, about 53 s.
- Test-running Mill calls in prepare.sh are capped at 600 s; a timeout counts as FAIL. On the `noise` cut tree `???` in an object initialiser deadlocks weaver, so `hidden_fails_on_cut=yes` there comes from the cap.
