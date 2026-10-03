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
  warm-cache.sh             build ~/gate-eval/cache/out/ once from a full HEAD tree
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

### 1. Warm the cache (one-time)

```bash
sh eval/gate-ab/warm-cache.sh
```

Prebuild necessary components.

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
- `~/gate-eval/head/` — full HEAD tree cache
- `~/gate-eval/cache/out/` — compilation cache
- `~/gate-eval/runs/results.csv` — aggregated results from report.py
- `~/gate-eval/runs/summary.md` — human-readable summary from report.py

## Testing

```bash
# Test under sh
sh eval/gate-ab/tests/shell-test.sh

# Test under dash
SH=dash dash eval/gate-ab/tests/shell-test.sh
```

Expected: 9 passed, 0 failed (both shells).

## Preparing the cache and tasks

`sh warm-cache.sh` once (about 1 min), then `sh prepare.sh <task>` per task (about 1 min each; `noise` takes about 11 min because its hidden spec hangs on the stub, see below). Mill selectors used: `__.compile` and `__.test.compile` (both valid in skreeep2 at 6bf6c1b).

- Mill records absolute paths in its output, and a run in a copy of the output overwrites the directory those paths name. warm-cache.sh therefore compiles in a sacrificial `~/gate-eval/cache-build` and gives `head/out` and `cache/out` their own copies; compiling in `head` itself made later copies delete `head`'s class directories.
- Test-running Mill calls in prepare.sh are capped at 600 s; a timeout counts as FAIL. On the `noise` cut tree `???` in an object initialiser deadlocks weaver, so `hidden_fails_on_cut=yes` there comes from the cap.
