# Gate Evaluation (gated vs ungated) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and run an A/B evaluation that measures whether the skreeep2 gate makes a `claude -p` agent's finished work more correct, and at what cost.

**Architecture:** `eval/gate-ab/` in scala-llm-template holds task definitions (stub files + metadata), `prepare.sh` (export skreeep2 at a pinned commit, apply a task's stubs, validate), `run.sh` (one run in an isolated directory under `~/gate-eval/runs/`), `score.py` (hidden spec, holdout, regressions, transcript metrics), `report.py` (per-arm statistics and the pre-registered decision rule) and `campaign.sh` (48 interleaved runs, resumable). Task files never enter a run directory.

**Tech Stack:** POSIX sh (sh and dash clean), Python 3 stdlib only (`unittest`, `json`, `csv`, `subprocess`, `math`), Mill 1.1.8 (`./mill` in the skreeep2 tree), `claude` CLI 2.1.x headless (`-p --output-format stream-json --verbose`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-03-gate-evaluation-design.md`

## Global Constraints

- skreeep2 source pinned at commit `6bf6c1b` (`SKREEEP2_COMMIT`); repository `/Users/viktorskalinins/IdeaProjects/skreeep2`.
- Holdout pinned at `/Users/viktorskalinins/IdeaProjects/skreeep2-holdout` commit `8207d2f`.
- Run root `~/gate-eval/` (base trees in `~/gate-eval/base/<task>/`, runs in `~/gate-eval/runs/<run-id>/`); never under `IdeaProjects`.
- Model `sonnet`; cap 45 minutes (`2700` s) per run; timeout = not solved.
- Both arms: `--permission-mode acceptEdits --allowedTools Bash Edit Write Read Grep Glob mcp__scala-semantic`; `.mcp.json` with `scala-semantic` only; no `settings.local.json`.
- Gated settings = skreeep2's `/Users/viktorskalinins/IdeaProjects/skreeep2/.claude/settings.json` with every `/Users/viktorskalinins/IdeaProjects/skreeep2-holdout` string replaced by the run's holdout copy path; ungated settings = `{"permissions":{}}`.
- 8 tasks × 2 arms × 3 repeats = 48 scored runs; order G,U alternating; run ids `<task>-<arm>-<rep>` with arm `g`/`u`, rep `1..3`.
- Decision rule (fixed): gate pays off if gated solve rate − ungated ≥ 0.20, or `false_done` count halved or better, AND median gated wall time ≤ 2 × ungated; |Δ solve rate| < 0.25 reported as inconclusive.
- Commits end with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`; no `Co-Authored-By`; stage explicit paths.
- Never modify `/Users/viktorskalinins/IdeaProjects/skreeep2` or the holdout repo from this plan; read them only (`git archive`, `cp`).
- macOS has no `timeout(1)`: time limits go through `eval/gate-ab/timeout.py`.

## Review Focus

1. A run that crashes before writing a result event (claude exits non-zero, transcript empty) must still produce a `score.json` with `solved=false`, `error` set — not abort the campaign. Test in Task 5.
2. A re-run of `campaign.sh` after an interruption must skip runs that already have `score.json` and redo half-finished ones (run dir without `score.json`). Test in Task 7.
3. Contamination: a `Read`/`Grep`/`Glob` path or a `Bash` command naming an absolute path outside the run directory (other than `/tmp`, `/var/folders`, `~/.cache`, `~/Library/Caches`, `/opt/homebrew`, `/usr`) marks `contaminated=true`. Test in Task 5.
4. Hidden-spec run that fails to COMPILE (agent changed a signature) counts as `hidden_pass_ratio=0`, `solved=false`, not as a scorer error. Test in Task 5.
5. Test tampering must ignore new test files the agent adds but flag modified or deleted existing `*/test/src/**` files. Test in Task 5.

---

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

---

### Task 1: Skeleton, lib.sh, timeout.py

**Files:**
- Create: `eval/gate-ab/lib.sh`, `eval/gate-ab/timeout.py`, `eval/gate-ab/README.md`, `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Produces: `lib.sh` variables `GA_HOME` (dir of lib.sh), `GA_ROOT` (default `$HOME/gate-eval`, override env `GA_ROOT`), `GA_SKREEEP2` (default `/Users/viktorskalinins/IdeaProjects/skreeep2`), `GA_COMMIT=6bf6c1b`, `GA_HOLDOUT_SRC` (default `/Users/viktorskalinins/IdeaProjects/skreeep2-holdout`), `GA_HOLDOUT_COMMIT=8207d2f`, `GA_CAP_SECONDS=2700`, `GA_MODEL=sonnet`, `GA_TASKS` (space-separated: `noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth`); functions `ga_die <msg>` (stderr, exit 1), `ga_task_env <task>` (sources `tasks/<task>/task.env`, dies if missing), `ga_run_id <task> <arm> <rep>` (prints `<task>-<arm>-<rep>`, dies unless arm is `g`/`u` and rep is 1..9).
- Produces: `timeout.py <seconds> -- <cmd...>`: exit code of cmd, or `124` on timeout after killing the whole process group (SIGTERM, 10 s, SIGKILL).

- [ ] **Step 1: Write the failing shell test**

`eval/gate-ab/tests/shell-test.sh`:
```sh
#!/bin/sh
# Tests for eval/gate-ab shell pieces. Runs under sh and dash. SH=dash sh tests/shell-test.sh to pick the shell.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ga=$(CDPATH= cd -- "$here/.." && pwd)
SH=${SH:-sh}
passed=0; failed=0
ok() { passed=$((passed+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1${2:+ -- $2}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted [$3], got [$2]"; fi; }

# --- lib.sh
out=$($SH -c ". '$ga/lib.sh'; ga_run_id noise g 1")
check "run id" "$out" "noise-g-1"
$SH -c ". '$ga/lib.sh'; ga_run_id noise x 1" >/dev/null 2>&1; check "run id rejects arm x" "$?" "1"
$SH -c ". '$ga/lib.sh'; ga_run_id noise g 0" >/dev/null 2>&1; check "run id rejects rep 0" "$?" "1"
out=$($SH -c "GA_ROOT=/tmp/x; . '$ga/lib.sh'; echo \$GA_ROOT")
check "GA_ROOT override" "$out" "/tmp/x"
out=$($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS" | wc -w | tr -d ' ')
check "eight tasks" "$out" "8"

# --- timeout.py
python3 "$ga/timeout.py" 5 -- sh -c 'exit 3'; check "timeout passes exit code" "$?" "3"
start=$(date +%s)
python3 "$ga/timeout.py" 1 -- sh -c 'sleep 30 & sleep 30'; rc=$?
took=$(( $(date +%s) - start ))
check "timeout returns 124" "$rc" "124"
[ "$took" -lt 15 ] && ok "timeout kills the group fast" || bad "timeout kills the group fast" "took ${took}s"

echo "shell-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh eval/gate-ab/tests/shell-test.sh`
Expected: FAIL lines (lib.sh / timeout.py missing).

- [ ] **Step 3: Write lib.sh**

```sh
# eval/gate-ab/lib.sh — sourced, never executed. Paths and constants for the gate A/B evaluation.
GA_HOME=${GA_HOME:-$(CDPATH= cd -- "$(dirname -- "${GA_LIB_PATH:-$0}")" 2>/dev/null && pwd)}
GA_ROOT=${GA_ROOT:-$HOME/gate-eval}
GA_SKREEEP2=${GA_SKREEEP2:-/Users/viktorskalinins/IdeaProjects/skreeep2}
GA_COMMIT=${GA_COMMIT:-6bf6c1b}
GA_HOLDOUT_SRC=${GA_HOLDOUT_SRC:-/Users/viktorskalinins/IdeaProjects/skreeep2-holdout}
GA_HOLDOUT_COMMIT=${GA_HOLDOUT_COMMIT:-8207d2f}
GA_CAP_SECONDS=${GA_CAP_SECONDS:-2700}
GA_MODEL=${GA_MODEL:-sonnet}
GA_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"

ga_die() { printf 'gate-ab: %s\n' "$1" >&2; exit 1; }

ga_task_env() {
  [ -f "$GA_HOME/tasks/$1/task.env" ] || ga_die "no task $1 ($GA_HOME/tasks/$1/task.env)"
  . "$GA_HOME/tasks/$1/task.env"
}

ga_run_id() {
  case $2 in g|u) ;; *) ga_die "arm must be g or u, got $2" ;; esac
  case $3 in [1-9]) ;; *) ga_die "rep must be 1..9, got $3" ;; esac
  printf '%s-%s-%s\n' "$1" "$2" "$3"
}
```

Because `$0` is the caller when sourced, scripts set `GA_LIB_PATH` before sourcing: every script starts with
`GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"`. In shell-test.sh the inline
`. '$ga/lib.sh'` form needs `GA_HOME` only for `ga_task_env`; tests that use it export `GA_HOME=$ga`.

- [ ] **Step 4: Write timeout.py**

```python
#!/usr/bin/env python3
"""timeout.py <seconds> -- <cmd...>: run cmd in its own process group; on timeout SIGTERM the group, wait 10 s, SIGKILL; exit 124."""
import os, signal, subprocess, sys

def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        sys.stderr.write("usage: timeout.py <seconds> -- <cmd...>\n")
        return 2
    limit = float(argv[1])
    proc = subprocess.Popen(argv[3:], start_new_session=True)
    try:
        return proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            try:
                proc.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                continue
        return 124

if __name__ == "__main__":
    sys.exit(main(sys.argv))
```

- [ ] **Step 5: README.md** — one page: purpose (link the spec path above), layout (the File Structure block), commands in order: `sh eval/gate-ab/warm-cache.sh`, `sh eval/gate-ab/prepare.sh <task>` for each task, `sh eval/gate-ab/campaign.sh --smoke`, `sh eval/gate-ab/campaign.sh`, `python3 eval/gate-ab/report.py ~/gate-eval/runs`; where results live (`~/gate-eval/runs/<run-id>/`).

- [ ] **Step 6: Run tests under both shells**

Run: `sh eval/gate-ab/tests/shell-test.sh && SH=dash dash eval/gate-ab/tests/shell-test.sh`
Expected: `shell-test: 8 passed, 0 failed` twice.

- [ ] **Step 7: Commit**

```bash
git add eval/gate-ab/lib.sh eval/gate-ab/timeout.py eval/gate-ab/README.md eval/gate-ab/tests/shell-test.sh
git commit -m "eval(gate-ab): skeleton — lib.sh constants, timeout.py, README

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 2: The eight task definitions and stubs

**Files:**
- Create: `eval/gate-ab/tasks/<task>/task.env`, `eval/gate-ab/tasks/<task>/prompt.txt`, `eval/gate-ab/tasks/<task>/stub/<path>` for the 8 tasks below.

**Interfaces:**
- Produces: `task.env` with exactly these shell assignments (values single-quoted):
  `TASK_MODULE` (Mill module of the hidden spec's test, e.g. `signals.test`), `HIDDEN_SPEC` (repo-relative path, one file), `CUT_FILES` (space-separated repo-relative paths; each has a stub at `stub/<path>`), `FEATURE` (short noun phrase used in the prompt).
- Produces: `prompt.txt` = exactly:
  `The implementation of <FEATURE> in <CUT_FILES, comma-separated> has been removed: its members are ???. Implement it as its scaladoc and the project's docs describe. The existing tests must keep passing. Stop when you are done.`

**Stub rules (apply to every cut file; read from skreeep2 at `6bf6c1b` with `git -C /Users/viktorskalinins/IdeaProjects/skreeep2 show 6bf6c1b:<path>`):**
1. Keep: package, the file's scaladoc and every public member's scaladoc and signature (name, type params, params, result type, `extends`, `derives`), case classes / enums / opaque types / traits that are DATA (fields only) unchanged.
2. Every public `def` body → `???`. Every public `val` whose right side computes behaviour → `???` with its declared type (add the type if it was inferred). Keep a public `val` that is a plain constant the scaladoc names as part of the contract only if listed under "keep" below.
3. Delete every `private`/`private[...]` member.
4. Remove imports that become unused (the build has `-Wunused:imports` and `-Werror`).
5. Do not touch any other file.

| Task | CUT_FILES | TASK_MODULE / HIDDEN_SPEC | FEATURE | Keep (besides rule 1) |
|---|---|---|---|---|
| noise | `signals/src/com/github/mercurievv/skreeep2/signals/Noise.scala` | `signals.test` / `signals/test/src/com/github/mercurievv/skreeep2/NoiseSpec.scala` | `the hash noise generator Noise` | `val Levels: Int` signature only (body `???`) |
| mixer-modes | `control/src/com/github/mercurievv/skreeep2/control/MixerMode.scala` | `control.test` / `control/test/src/com/github/mercurievv/skreeep2/control/MixerModeSpec.scala` | `the mixer mode MixerMode` | case class `Mixer` unchanged |
| mcu | `control/midi/src/com/github/mercurievv/skreeep2/control/midi/Mcu.scala` | `control.midi.test` / `control/midi/test/src/com/github/mercurievv/skreeep2/control/midi/McuSpec.scala` | `the Mackie Control codec Mcu` | — |
| note-ring | `handoff/hostdriven/src/com/github/mercurievv/skreeep2/hostdriven/NoteRing.scala` | `handoff.hostdriven.test` / `handoff/hostdriven/test/src/com/github/mercurievv/skreeep2/hostdriven/NoteRingSpec.scala` | `the lock-free note ring NoteRing` | companion's `Raw` trait / data types unchanged |
| backpressure | `core/src/com/github/mercurievv/skreeep2/audio/AudioFormat.scala` | `backend.cpu.test` / `backend/cpu/test/src/com/github/mercurievv/skreeep2/BackpressureSpec.scala` | `the audio backpressure policy AudioBuffer.backpressureDelay and AudioBuffer.pipe` | everything in the file except the two bodies of `object AudioBuffer` (those two become `???`) |
| scope-view | `scope/src/io/github/mercurievv/scope/View.scala` | `scope.test` / `scope/test/src/io/github/mercurievv/scope/ViewSpec.scala` | `the scope's View and Axes geometry` | case class fields of `View` and `Axes` |
| modes | `control/src/com/github/mercurievv/skreeep2/control/Modes.scala` | `control.test` / `control/test/src/com/github/mercurievv/skreeep2/control/ModesSpec.scala` | `the mode sequencer Modes` | the `Held` trait's two abstract members |
| midi-synth | `plugin/src/com/github/mercurievv/skreeep2/plugin/MidiSynth.scala` | `plugin.test` / `plugin/test/src/com/github/mercurievv/skreeep2/plugin/MidiSynthSpec.scala` | `the pitch-keyed voice allocator MidiSynth` | case class `Allocation`, `Allocation.empty` |

Example — `tasks/midi-synth/stub/plugin/src/com/github/mercurievv/skreeep2/plugin/MidiSynth.scala`:
```scala
package com.github.mercurievv.skreeep2.plugin

import cats.data.State

/** Voice allocation for host notes, keyed by pitch instead of `Perform.synthesizer`'s round-robin: a note-off must reach the voice its note-on took,
  * and pitch is the only identity `Struck` carries (ADR-001). Limit: two simultaneous notes at the same pitch share one voice and the second
  * retriggers the first, ordinary monophonic-per-pitch behaviour — distinguishing them would need a note id added to `Struck`.
  */
object MidiSynth:

  /** Which pitch owns which slot, and where the round-robin is. */
  final case class Allocation(byPitch: Map[Double, Int], next: Int)

  object Allocation:
    val empty: Allocation = Allocation(Map.empty, 0)

  /** Assigns `pitch` a slot, reusing the one it already holds. When a new pitch steals another's slot, the old pitch's claim is dropped so its later
    * note-off cannot silence the new note.
    */
  def allocate(pitch: Double, polyphony: Int): State[Allocation, Int] = ???
```

`tasks/midi-synth/task.env`:
```sh
TASK_MODULE='plugin.test'
HIDDEN_SPEC='plugin/test/src/com/github/mercurievv/skreeep2/plugin/MidiSynthSpec.scala'
CUT_FILES='plugin/src/com/github/mercurievv/skreeep2/plugin/MidiSynth.scala'
FEATURE='the pitch-keyed voice allocator MidiSynth'
```

- [ ] **Step 1:** For each of the 8 tasks write `task.env` and `prompt.txt` (prompt from the template above, with `<CUT_FILES>` comma-separated).
- [ ] **Step 2:** For each task write `stub/<path>` by the stub rules; use the midi-synth example as the pattern.
- [ ] **Step 3: Structural test** — add to `tests/shell-test.sh` (before the summary line):
```sh
# --- task definitions
for t in $($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS"); do
  d="$ga/tasks/$t"
  [ -f "$d/task.env" ] && [ -f "$d/prompt.txt" ] || { bad "task $t has task.env and prompt.txt"; continue; }
  ( . "$d/task.env"
    for f in $CUT_FILES; do [ -f "$d/stub/$f" ] || exit 1; grep -q '???' "$d/stub/$f" || exit 1; done
    [ -n "$TASK_MODULE" ] && [ -n "$HIDDEN_SPEC" ] && [ -n "$FEATURE" ] ) && ok "task $t complete" || bad "task $t complete"
  grep -q 'Stop when you are done.' "$d/prompt.txt" && ok "task $t prompt" || bad "task $t prompt"
done
```
- [ ] **Step 4:** Run `sh eval/gate-ab/tests/shell-test.sh && SH=dash dash eval/gate-ab/tests/shell-test.sh` — expected `24 passed, 0 failed`. (Compilation of stubs is validated in Task 3.)
- [ ] **Step 5: Commit** `git add eval/gate-ab/tasks eval/gate-ab/tests/shell-test.sh` — message `eval(gate-ab): eight remove-and-rebuild tasks (stubs, prompts, hidden-spec paths)` + session trailer.

---

### Task 3: prepare.sh and warm-cache.sh (real Mill)

**Files:**
- Create: `eval/gate-ab/prepare.sh`, `eval/gate-ab/warm-cache.sh`
- Modify: `eval/gate-ab/tests/shell-test.sh` (fake-tree test)

**Interfaces:**
- Consumes: `lib.sh` (Task 1), `tasks/<task>/` (Task 2).
- Produces: `~/gate-eval/base/<task>/tree/` (cut tree, git repo with one commit `base`, no history of skreeep2), `~/gate-eval/base/<task>/hidden/<HIDDEN_SPEC>` (the spec, outside the tree), `~/gate-eval/base/<task>/validation.txt` with three lines `cut_compiles=yes|no`, `hidden_fails_on_cut=yes|no`, `hidden_passes_on_head=yes|no`; exit 0 only if all three are `yes`.
- Produces: `~/gate-eval/cache/out/` — Mill output of `./mill -j 1 __.compile` + `__.test.compile` on a full HEAD export (warm-cache.sh); `~/gate-eval/head/` — the full HEAD export (also used by score.py to compute baseline regressions).

`prepare.sh <task>`:
```sh
#!/bin/sh
# Build ~/gate-eval/base/<task>/: the cut tree (no git history), the hidden spec outside it, and a validation record.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 1 ] || ga_die "usage: prepare.sh <task>"
task=$1; ga_task_env "$task"
base=$GA_ROOT/base/$task
rm -rf "$base"; mkdir -p "$base/tree" "$base/hidden"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$base/tree" || ga_die "git archive failed"
mkdir -p "$base/hidden/$(dirname "$HIDDEN_SPEC")"
mv "$base/tree/$HIDDEN_SPEC" "$base/hidden/$HIDDEN_SPEC" || ga_die "hidden spec $HIDDEN_SPEC not in tree"
for f in $CUT_FILES; do cp "$GA_HOME/tasks/$task/stub/$f" "$base/tree/$f" || ga_die "stub $f"; done
( cd "$base/tree" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm base ) || ga_die "git init"

mill_in() { # <dir> <args...>: Mill with a private output dir, warm-started from the cache
  d=$1; shift
  [ -d "$GA_ROOT/cache/out" ] && [ ! -d "$d/out" ] && cp -R "$GA_ROOT/cache/out" "$d/out"
  ( cd "$d" && MILL_OUTPUT_DIR=out python3 "$GA_HOME/timeout.py" 1800 -- ./mill --no-daemon -j 1 --ticker false --color false "$@" )
}

v=$base/validate; rm -rf "$v"; cp -R "$base/tree" "$v"
mill_in "$v" __.compile >"$base/cut-compile.log" 2>&1 && c=yes || c=no
mkdir -p "$v/$(dirname "$HIDDEN_SPEC")"; cp "$base/hidden/$HIDDEN_SPEC" "$v/$HIDDEN_SPEC"
mill_in "$v" "$TASK_MODULE" >"$base/hidden-on-cut.log" 2>&1 && f=no || f=yes
h=$GA_ROOT/head
[ -d "$h" ] || ga_die "no $h — run warm-cache.sh first"
mill_in "$h" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
rm -rf "$v"
printf 'cut_compiles=%s\nhidden_fails_on_cut=%s\nhidden_passes_on_head=%s\n' "$c" "$f" "$p" | tee "$base/validation.txt"
[ "$c$f$p" = yesyesyes ]
```
`mill_in` on `$h` uses `$h/out` (created by warm-cache.sh), so HEAD runs stay warm.

`warm-cache.sh`:
```sh
#!/bin/sh
# Export skreeep2 at GA_COMMIT to ~/gate-eval/head and compile everything once; ~/gate-eval/cache/out is the warm Mill output every run copies.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
h=$GA_ROOT/head
rm -rf "$h" "$GA_ROOT/cache"; mkdir -p "$h" "$GA_ROOT/cache"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$h" || ga_die "git archive failed"
( cd "$h" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm head ) || ga_die "git init"
( cd "$h" && MILL_OUTPUT_DIR=out ./mill --no-daemon -j 1 --ticker false --color false __.compile + __.test.compile ) || ga_die "HEAD does not compile"
cp -R "$h/out" "$GA_ROOT/cache/out"
echo "warm cache: $GA_ROOT/cache/out"
```
If `__.test.compile` is not a valid selector in this build, use the `testCompileModules` list from skreeep2's `build.mill` (`git show 6bf6c1b:build.mill | grep -n testCompile`) — record which in the README.

- [ ] **Step 1: Failing test** — append to `tests/shell-test.sh` a fake-tree test that runs `prepare.sh` with `GA_SKREEEP2` pointing at a tiny git repo built in a temp dir (one `./mill` script stub that exits 0 for `__.compile`, exits 1 when the hidden spec file exists for `TASK_MODULE`, exits 0 in `$GA_ROOT/head`), `GA_HOME` at a temp copy with one task `t1`, `GA_ROOT` at a temp dir; assert `validation.txt` is three `=yes` lines, `tree/.git` has exactly one commit (`git -C tree rev-list --count HEAD` = 1), and `tree/<HIDDEN_SPEC>` does not exist.
- [ ] **Step 2:** Run it, see FAIL (prepare.sh missing).
- [ ] **Step 3:** Write `prepare.sh` and `warm-cache.sh` as above.
- [ ] **Step 4:** Run shell-test under sh and dash: all pass.
- [ ] **Step 5: Real run** — `sh eval/gate-ab/warm-cache.sh`, then `for t in noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth; do sh eval/gate-ab/prepare.sh $t; done`. Every task must print three `=yes`. A task that does not: fix its STUB (Task 2 rules) if the cut does not compile; if the hidden spec passes on the cut tree or fails on HEAD, replace the task with another spec at HEAD (list: `git -C /Users/viktorskalinins/IdeaProjects/skreeep2 ls-files '*/test/src/*.scala'`) and record the swap in the README.
- [ ] **Step 6: Commit** `eval/gate-ab/prepare.sh eval/gate-ab/warm-cache.sh eval/gate-ab/tests/shell-test.sh` (+ any stub fixes) — `eval(gate-ab): prepare and warm cache — cut trees without history, three-way validation`.

---

### Task 4: run.sh — one run

**Files:**
- Create: `eval/gate-ab/run.sh`
- Modify: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Consumes: `~/gate-eval/base/<task>/tree`, `~/gate-eval/cache/out`, `lib.sh`, `timeout.py`.
- Produces: `~/gate-eval/runs/<run-id>/` containing `repo/` (the agent's working tree), `holdout/` (gated arm only), `prompt.txt`, `settings.json` (copy of what the arm used), `transcript.jsonl`, `run.json` (`{"run_id","task","arm","rep","start_epoch","end_epoch","exit_code","timed_out"}`), `final.diff` (`git -C repo diff base` incl. untracked: `git add -A -N` first), `final-tree.tar.gz`. Env `CLAUDE_BIN` (default `claude`) lets tests substitute a fake.

```sh
#!/bin/sh
# One evaluation run: run.sh <task> <g|u> <rep>. Builds the run dir from the task's base tree, runs the agent, collects artefacts.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 3 ] || ga_die "usage: run.sh <task> <g|u> <rep>"
task=$1; arm=$2; rep=$3; id=$(ga_run_id "$task" "$arm" "$rep") || exit 1
ga_task_env "$task"
base=$GA_ROOT/base/$task
[ -d "$base/tree/.git" ] || ga_die "task $task not prepared (run prepare.sh $task)"
rd=$GA_ROOT/runs/$id
rm -rf "$rd"; mkdir -p "$rd"
cp -R "$base/tree" "$rd/repo"
cp "$GA_HOME/tasks/$task/prompt.txt" "$rd/prompt.txt"
mkdir -p "$rd/repo/.claude"
cat > "$rd/repo/.mcp.json" <<'EOF'
{ "mcpServers": { "scala-semantic": { "command": "/Users/viktorskalinins/.local/bin/scalasemantic-mcp", "args": ["serve", "."] } } }
EOF
if [ "$arm" = g ]; then
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | { mkdir -p "$rd/holdout" && tar -x -C "$rd/holdout"; } || ga_die "holdout export"
  hd=$(CDPATH= cd -- "$rd/holdout" && pwd -P)
  sed "s|$GA_HOLDOUT_SRC|$hd|g" "$GA_SKREEEP2/.claude/settings.json" > "$rd/repo/.claude/settings.json"
  sed -i.bak "s|^holdoutDir *=.*|holdoutDir = $hd|" "$rd/repo/.dsh/contract" && rm -f "$rd/repo/.dsh/contract.bak"
  cp -R "$GA_ROOT/cache/out" "$rd/repo/out-agent"
else
  printf '{"permissions":{}}\n' > "$rd/repo/.claude/settings.json"
  cp -R "$GA_ROOT/cache/out" "$rd/repo/out"
fi
cp "$rd/repo/.claude/settings.json" "$rd/settings.json"
( cd "$rd/repo" && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qam "arm $arm" --allow-empty && git tag base )
start=$(date +%s)
( cd "$rd/repo" && python3 "$GA_HOME/timeout.py" "$GA_CAP_SECONDS" -- "${CLAUDE_BIN:-claude}" -p "$(cat "$rd/prompt.txt")" \
    --model "$GA_MODEL" --output-format stream-json --verbose \
    --permission-mode acceptEdits --allowedTools Bash Edit Write Read Grep Glob mcp__scala-semantic ) \
  > "$rd/transcript.jsonl" 2> "$rd/agent-stderr.log"
rc=$?; end=$(date +%s)
to=false; [ "$rc" -eq 124 ] && to=true
printf '{"run_id":"%s","task":"%s","arm":"%s","rep":%s,"start_epoch":%s,"end_epoch":%s,"exit_code":%s,"timed_out":%s}\n' \
  "$id" "$task" "$arm" "$rep" "$start" "$end" "$rc" "$to" > "$rd/run.json"
( cd "$rd/repo" && git add -A -N . && git diff base -- . ':!out' ':!out-agent' ':!out-holdout' > "$rd/final.diff" )
tar -czf "$rd/final-tree.tar.gz" -C "$rd" --exclude 'repo/out' --exclude 'repo/out-agent' --exclude 'repo/out-holdout' repo
echo "run $id: exit $rc, $((end-start)) s"
```
Note: `.claude/` and `.mcp.json` are gitignored in skreeep2, so the `arm` commit holds only the contract change; `base` tag marks the agent's starting point either way.

- [ ] **Step 1: Failing test** — in shell-test.sh, with temp `GA_ROOT` holding a fake `base/t1/tree` (git repo with `.dsh/contract` containing `holdoutDir = ../x`, a `.gitignore` with `.claude/` `out/` `out-agent/`), fake `cache/out/`, fake holdout git repo (`GA_HOLDOUT_SRC`, `GA_HOLDOUT_COMMIT=HEAD`), fake skreeep2 settings at `$GA_SKREEEP2/.claude/settings.json` containing the holdout path, and `CLAUDE_BIN` = a script that prints two stream-json lines and appends a line to a file in cwd: assert for arm `g`: `run.json` has `"timed_out":false`, `repo/.claude/settings.json` contains the run's holdout path and not `GA_HOLDOUT_SRC`, `repo/.dsh/contract` holdoutDir is absolute under the run dir, `repo/out-agent` exists, `final.diff` contains the fake agent's line, `final-tree.tar.gz` exists; for arm `u`: settings is `{"permissions":{}}`, `repo/out` exists, no `holdout/` dir. A third case with `GA_CAP_SECONDS=1` and a fake agent that sleeps 20: `"timed_out":true`.
- [ ] **Step 2:** Run, see FAIL.
- [ ] **Step 3:** Write run.sh.
- [ ] **Step 4:** shell-test passes under sh and dash.
- [ ] **Step 5: Commit** `eval/gate-ab/run.sh eval/gate-ab/tests/shell-test.sh` — `eval(gate-ab): run.sh — one isolated run per arm, artefacts preserved`.

---

### Task 5: score.py

**Files:**
- Create: `eval/gate-ab/score.py`, `eval/gate-ab/tests/test_score.py`, `eval/gate-ab/tests/fixtures/transcripts/*.jsonl`

**Interfaces:**
- Consumes: a run dir from Task 4; `~/gate-eval/base/<task>/hidden/`; `~/gate-eval/head/` (baseline); holdout source at `GA_HOLDOUT_SRC`@`GA_HOLDOUT_COMMIT`.
- Produces: `<run-dir>/score.json` with keys: `run_id, task, arm, rep, solved (bool), hidden_pass_ratio (float), hidden_compiled (bool), holdout_passed (bool), regressions (list of module ids), test_tampering (list of paths), hardcoding_suspects (list of str), false_done (bool), timed_out (bool), contaminated (bool), contamination (list of str), gate_blocks (dict reason->count), wall_seconds (int), turns (int|null), input_tokens, output_tokens, cache_read_tokens (int|null), cost_usd (float|null), first_clean_compile_turn (int|null), error (str|null)`.
- Pure functions (unit-tested): `parse_transcript(lines) -> dict` (turns, tokens, cost, tool_calls list of `{name, input, result_text, is_error, turn}`, final_text), `weaver_counts(log_text) -> (passed, failed, compiled)`, `contamination(tool_calls, run_dir) -> list[str]`, `tampering(diff_text) -> list[str]`, `gate_blocks(tool_calls, transcript_texts) -> dict`, `hardcoding(diff_text, hidden_spec_text) -> list[str]`, `first_clean_compile(tool_calls) -> int|None`.

Rules:
- Scoring copy: `cp -R <run>/repo <run>/score-tree` (minus nothing), put `hidden/<HIDDEN_SPEC>` into it, use `MILL_OUTPUT_DIR=out-score` warm-started from `~/gate-eval/cache/out`; run `./mill --no-daemon -j 1 --ticker false --color false <TASK_MODULE>` → `hidden-score.log`; `weaver_counts`: weaver prints `+ <name>` per pass and `- <name>` per failure (ANSI stripped); `compiled` false when the log has `Compilation failed`. `hidden_pass_ratio = passed/(passed+failed)`, 0 when not compiled or no tests.
- Holdout: run `holdout.test` in the scoring copy with `DSH_HOLDOUT_DIR=<absolute holdout export>` → `holdout-score.log`; `holdout_passed` = exit 0 and 7 `+` lines.
- Regressions: for each module id in `~/gate-eval/head/.dsh/.state/modules.tsv`-equivalent — use the scoring copy's `./mill --no-daemon -j 1 --ticker false --color false resolve __.test` to list test modules — run each `<m>` (excluding `TASK_MODULE`, `holdout.test`) in the scoring copy; a module failing there but passing in `~/gate-eval/head` (baseline cached in `~/gate-eval/head-baseline.json`, computed once on first use) is a regression. Exclude `backend.opencl.test` and any module whose baseline fails.
- `solved` = hidden compiled, hidden failed == 0, passed > 0, holdout_passed, regressions empty, not timed_out.
- `false_done` = not timed_out and exit_code == 0 and not solved.
- `test_tampering`: from `final.diff` `diff --git a/X b/X` headers where X matches `/test/src/` and the hunk is not `new file mode` → list X.
- `hardcoding`: string literals (`"..."`) and numeric literals with ≥3 significant chars from the hidden spec that appear on `+` lines of the diff outside test dirs; reported only.
- Contamination: for tool calls `Read`/`Grep`/`Glob` (fields `file_path`/`path`/`pattern`) and `Bash` (`command`), every absolute path token `/…` that is not under the run dir (realpath) and not under the allowed prefixes `/tmp`, `/private/tmp`, `/var/folders`, `/private/var/folders`, `$HOME/.cache`, `$HOME/Library/Caches`, `$HOME/.local/bin`, `/opt/homebrew`, `/usr`, `/bin`, `/dev/null` → entry `"<tool>: <path>"`. Also `Bash` commands containing `git -C ` with a path outside. `contaminated = bool(list)`.
- `gate_blocks`: count tool results with `is_error` true whose text contains `BLOCKED by <hook>` (key = hook name), `SEALED PATH` (key `semantic-guard-sealed`), and any text block anywhere in the transcript starting `Stop hook feedback` or containing `turn-end` + `BLOCKED` (key `turn-end`). The smoke run (Task 7) checks these patterns against real gate output; adjust and add a fixture if they differ.
- `first_clean_compile`: the turn index of the first `Bash` call whose command contains `./mill` and `compile` and whose result is not an error and has no `[error]`.
- Any exception → `score.json` with `solved=false`, `error=<repr>`, other fields best-effort. Missing/empty transcript → turns etc. null, `error="no result event"` unless a result event exists.

Transcript format (stream-json, one object per line): `{"type":"assistant","message":{"content":[{"type":"tool_use","id":..,"name":..,"input":{..}}|{"type":"text","text":..}]}}`, `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":..,"content":str|[{"type":"text","text":..}],"is_error":bool}]}}`, final `{"type":"result","subtype":"success"|"error_max_turns"|..,"is_error":bool,"num_turns":int,"total_cost_usd":float,"duration_ms":int,"usage":{"input_tokens":int,"output_tokens":int,"cache_read_input_tokens":int},"result":str}`.

- [ ] **Step 1: Fixtures** — `tests/fixtures/transcripts/clean.jsonl` (2 assistant turns: a `Bash` `./mill -j 1 signals.compile` with ok result, a final text; result event with num_turns 2, cost 0.42, usage 1000/200/5000), `blocked.jsonl` (a `Bash` result `is_error:true` text `BLOCKED by tool-policy: holdout.test runs the SEALED holdout suite`, a `Read` result `semantic-guard: .dsh/.state/holdout.log is a SEALED PATH`), `contaminated.jsonl` (a `Read` of `/Users/viktorskalinins/IdeaProjects/skreeep2/signals/src/x.scala`, a `Bash` `ls /tmp/foo`), `empty.jsonl` (0 bytes).
- [ ] **Step 2: Failing tests** `tests/test_score.py` (unittest):
```python
import os, sys, unittest, pathlib
HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent))
import score

FX = HERE / "fixtures" / "transcripts"

def lines(name): return (FX / name).read_text().splitlines()

class Transcript(unittest.TestCase):
    def test_clean_metrics(self):
        t = score.parse_transcript(lines("clean.jsonl"))
        self.assertEqual(t["turns"], 2); self.assertAlmostEqual(t["cost_usd"], 0.42)
        self.assertEqual((t["input_tokens"], t["output_tokens"], t["cache_read_tokens"]), (1000, 200, 5000))
    def test_empty_transcript(self):
        t = score.parse_transcript([])
        self.assertIsNone(t["turns"]); self.assertEqual(t["tool_calls"], [])
    def test_first_clean_compile(self):
        t = score.parse_transcript(lines("clean.jsonl"))
        self.assertEqual(score.first_clean_compile(t["tool_calls"]), 1)

class Blocks(unittest.TestCase):
    def test_counts_by_hook(self):
        t = score.parse_transcript(lines("blocked.jsonl"))
        b = score.gate_blocks(t["tool_calls"], t["texts"])
        self.assertEqual(b.get("tool-policy"), 1); self.assertEqual(b.get("semantic-guard-sealed"), 1)

class Contamination(unittest.TestCase):
    def test_outside_read_flagged_tmp_allowed(self):
        t = score.parse_transcript(lines("contaminated.jsonl"))
        c = score.contamination(t["tool_calls"], "/Users/someone/gate-eval/runs/noise-g-1")
        self.assertEqual(len(c), 1); self.assertIn("IdeaProjects/skreeep2", c[0])
    def test_inside_run_dir_allowed(self):
        calls = [{"name": "Read", "input": {"file_path": "/r/run/repo/a.scala"}, "result_text": "", "is_error": False, "turn": 1}]
        self.assertEqual(score.contamination(calls, "/r/run"), [])

class Weaver(unittest.TestCase):
    def test_counts(self):
        log = "\x1b[32m+ \x1b[0ma passes 1ms\n\x1b[31m- \x1b[0mb fails 2ms\n+ c 3ms\n"
        self.assertEqual(score.weaver_counts(log), (2, 1, True))
    def test_compile_failure(self):
        self.assertEqual(score.weaver_counts("[error] x.test.compile Compilation failed\n"), (0, 0, False))

class Tampering(unittest.TestCase):
    def test_modified_flagged_new_ignored(self):
        diff = ("diff --git a/x/test/src/A.scala b/x/test/src/A.scala\nindex 1..2 100644\n"
                "diff --git a/x/test/src/B.scala b/x/test/src/B.scala\nnew file mode 100644\n"
                "diff --git a/x/src/C.scala b/x/src/C.scala\nindex 1..2 100644\n")
        self.assertEqual(score.tampering(diff), ["x/test/src/A.scala"])
    def test_deleted_flagged(self):
        diff = "diff --git a/x/test/src/A.scala b/x/test/src/A.scala\ndeleted file mode 100644\n"
        self.assertEqual(score.tampering(diff), ["x/test/src/A.scala"])

class Hardcoding(unittest.TestCase):
    def test_literal_from_spec_in_src_plus_line(self):
        spec = 'expect(f(3) == 2039.0)\nexpect(name == "kick-drum")'
        diff = 'diff --git a/s/src/N.scala b/s/src/N.scala\n+  val p = 2039.0\n+  val n = "kick-drum"\n-  old 2039.0\n'
        self.assertEqual(sorted(score.hardcoding(diff, spec)), ['"kick-drum"', "2039.0"])

class Verdict(unittest.TestCase):
    def test_solved_requires_everything(self):
        base = dict(hidden_compiled=True, hidden_passed=5, hidden_failed=0, holdout_passed=True, regressions=[], timed_out=False)
        self.assertTrue(score.is_solved(**base))
        self.assertFalse(score.is_solved(**{**base, "hidden_compiled": False}))
        self.assertFalse(score.is_solved(**{**base, "hidden_passed": 0}))
        self.assertFalse(score.is_solved(**{**base, "regressions": ["control.test"]}))
        self.assertFalse(score.is_solved(**{**base, "timed_out": True}))
    def test_false_done(self):
        self.assertTrue(score.is_false_done(solved=False, timed_out=False, exit_code=0))
        self.assertFalse(score.is_false_done(solved=False, timed_out=True, exit_code=124))
        self.assertFalse(score.is_false_done(solved=True, timed_out=False, exit_code=0))

if __name__ == "__main__":
    unittest.main()
```
- [ ] **Step 3:** Run `python3 -m unittest discover -s eval/gate-ab/tests -p 'test_score.py' -v` — FAIL (no module).
- [ ] **Step 4: Implement score.py** — the pure functions above plus `is_solved(hidden_compiled, hidden_passed, hidden_failed, holdout_passed, regressions, timed_out)`, `is_false_done(solved, timed_out, exit_code)`, and `main(run_dir)` doing the Mill runs per the Rules (subprocess with `timeout=1800`, env `MILL_OUTPUT_DIR`), writing `score.json` atomically (`score.json.tmp` → `os.replace`). ANSI strip regex `\x1b\[[0-9;]*m`. CLI: `python3 score.py <run-dir>`; env `GA_ROOT`, `GA_HOLDOUT_SRC`, `GA_HOLDOUT_COMMIT` with the lib.sh defaults; reads `tasks/<task>/task.env` with a tiny `KEY='value'` parser.
- [ ] **Step 5:** Tests pass.
- [ ] **Step 6: Commit** `eval/gate-ab/score.py eval/gate-ab/tests/test_score.py eval/gate-ab/tests/fixtures` — `eval(gate-ab): score.py — hidden spec, holdout, regressions, integrity and cost from the transcript`.

---

### Task 6: report.py

**Files:**
- Create: `eval/gate-ab/report.py`, `eval/gate-ab/tests/test_report.py`

**Interfaces:**
- Consumes: `~/gate-eval/runs/*/score.json` (Task 5 keys).
- Produces: `<runs-root>/results.csv` (one row per run, columns = score.json scalar keys + `gate_blocks_total`), `<runs-root>/summary.md`; functions `wilson(k, n, z=1.96) -> (lo, hi)`, `sign_test(diffs) -> p_two_sided` (ties dropped, exact binomial), `decide(g, u) -> str` where `g`/`u` are dicts `{solve_rate, false_done, median_wall}` returning one of `pays off`, `does not pay off`, `inconclusive`.

Decision (from Global Constraints): `pays off` if (`g.solve_rate - u.solve_rate >= 0.20` or (`u.false_done > 0` and `g.false_done <= u.false_done / 2`)) and `g.median_wall <= 2 * u.median_wall`; else `inconclusive` if `abs(g.solve_rate - u.solve_rate) < 0.25`; else `does not pay off`. Contaminated runs and runs with `error` are excluded from the headline and counted separately.

summary.md sections: per-arm table (n, solved, solve rate + Wilson CI, false_done, tampering runs, contaminated, timeouts, median wall, median turns, median cost, total cost); per-task table (gated solved/3, ungated solved/3, diff); sign test p; gate_blocks by hook summed over the gated arm and the number of gated runs each hook fired in; the verdict line `Verdict: <decide>` with the rule quoted.

- [ ] **Step 1: Failing tests:**
```python
import sys, unittest, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
import report

class Stats(unittest.TestCase):
    def test_wilson_known_value(self):
        lo, hi = report.wilson(12, 24)
        self.assertAlmostEqual(lo, 0.314, places=3); self.assertAlmostEqual(hi, 0.686, places=3)
    def test_wilson_zero_n(self):
        self.assertEqual(report.wilson(0, 0), (0.0, 1.0))
    def test_sign_test(self):
        self.assertAlmostEqual(report.sign_test([1, 1, 1, 1, 1, 1, 1, 1]), 2 / 256)
        self.assertAlmostEqual(report.sign_test([1, -1, 0]), 1.0)

class Decide(unittest.TestCase):
    def d(self, gs, us, gf=0, uf=0, gw=100, uw=100):
        return report.decide({"solve_rate": gs, "false_done": gf, "median_wall": gw}, {"solve_rate": us, "false_done": uf, "median_wall": uw})
    def test_pays_off_on_solve_rate(self): self.assertEqual(self.d(0.8, 0.5), "pays off")
    def test_pays_off_on_false_done(self): self.assertEqual(self.d(0.6, 0.6, gf=2, uf=6), "pays off")
    def test_too_slow(self): self.assertEqual(self.d(0.8, 0.5, gw=300, uw=100), "does not pay off")
    def test_inconclusive(self): self.assertEqual(self.d(0.6, 0.5), "inconclusive")
    def test_worse(self): self.assertEqual(self.d(0.2, 0.6), "does not pay off")

if __name__ == "__main__":
    unittest.main()
```
- [ ] **Step 2:** Run — FAIL.
- [ ] **Step 3:** Implement report.py (stdlib only; `math.comb` for the binomial; median via `statistics.median`). CLI `python3 report.py <runs-root>`.
- [ ] **Step 4:** Tests pass; also a smoke: build 4 fake run dirs with score.json in a temp dir in a test `test_end_to_end` asserting `results.csv` has 4 rows and `summary.md` contains `Verdict:`.
- [ ] **Step 5: Commit** `eval/gate-ab/report.py eval/gate-ab/tests/test_report.py` — `eval(gate-ab): report.py — Wilson intervals, sign test, the pre-registered verdict`.

---

### Task 7: campaign.sh, then the smoke run

**Files:**
- Create: `eval/gate-ab/campaign.sh`
- Modify: `eval/gate-ab/tests/shell-test.sh`, possibly `score.py` (gate-block patterns), `README.md`

**Interfaces:**
- Consumes: run.sh, score.py.
- Produces: `campaign.sh [--smoke]`. Full order: for rep in 1 2 3, for task in GA_TASKS, for arm in g u → `run_id`; skip when `runs/<id>/score.json` exists; otherwise `run.sh` then `python3 score.py runs/<id>`. `--smoke`: only `midi-synth`, rep `9`, arms g then u (rep 9 keeps smoke runs out of the 1..3 scored set; report.py ignores rep 9). Appends one line per finished run to `$GA_ROOT/campaign.log`: `<date> <id> exit=<rc> solved=<bool>`. Env `GA_RUN=…`/`GA_SCORE=…` override the two commands for tests.

```sh
#!/bin/sh
# All runs in a fixed interleaved order; resumable — a run with score.json is done, a run dir without one is redone.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
run=${GA_RUN:-sh "$GA_HOME/run.sh"}; sc=${GA_SCORE:-python3 "$GA_HOME/score.py"}
one() {
  id=$(ga_run_id "$1" "$2" "$3") || exit 1
  [ -f "$GA_ROOT/runs/$id/score.json" ] && { echo "skip $id"; return 0; }
  $run "$1" "$2" "$3"; rc=$?
  $sc "$GA_ROOT/runs/$id"
  s=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('solved'))" "$GA_ROOT/runs/$id/score.json" 2>/dev/null || echo none)
  printf '%s %s exit=%s solved=%s\n' "$(date '+%F %T')" "$id" "$rc" "$s" >> "$GA_ROOT/campaign.log"
}
mkdir -p "$GA_ROOT/runs"
if [ "${1:-}" = --smoke ]; then one midi-synth g 9; one midi-synth u 9; exit 0; fi
for rep in 1 2 3; do for task in $GA_TASKS; do for arm in g u; do one "$task" "$arm" "$rep"; done; done; done
```

- [ ] **Step 1: Failing test** — shell-test: with `GA_RUN`/`GA_SCORE` fakes that record calls to a file and write `score.json`, run `campaign.sh` with `GA_ROOT` temp; assert 48 calls, first three ids `noise-g-1 noise-u-1 mixer-modes-g-1`; pre-create `runs/noise-g-1/score.json` and a half-run `runs/noise-u-1/` (no score.json) → re-run calls 47 and includes `noise-u-1`; `--smoke` calls exactly `midi-synth-g-9 midi-synth-u-9`.
- [ ] **Step 2:** Run — FAIL. **Step 3:** write campaign.sh. **Step 4:** pass under sh and dash. **Step 5: commit** `eval(gate-ab): campaign.sh — interleaved, resumable, smoke mode`.
- [ ] **Step 6: Smoke run (real)** — `sh eval/gate-ab/campaign.sh --smoke`. Then read `~/gate-eval/runs/midi-synth-{g,u}-9/score.json` and the transcripts' tool results:
  - both have a result event (`turns` not null), `final.diff` non-empty, `final-tree.tar.gz` present;
  - gated: `repo/out-agent` used, no `repo/out` created by the agent; holdout ran at turn-end (its log in `repo/.dsh/.state/holdout.log`);
  - `gate_blocks` patterns match what the gate printed — if the transcript shows a block the scorer missed, add a fixture with that exact text to `tests/fixtures/transcripts/` and a test in `test_score.py`, fix `gate_blocks`, re-run `python3 score.py` on both smoke runs;
  - contamination: list any flagged paths; if an allowed system path is flagged, add it to the allowed prefixes with a test.
  Record the smoke results (wall time, turns, cost, solved) in the README's "Smoke run" section. Commit any fixes with explicit paths.

---

### Task 8: The campaign and the report

**Files:**
- Modify: `eval/gate-ab/README.md` (results pointer)
- Create (in scala-coding-guidelines): `raw/llm-scala-fusion/2026-10-XX-local-gate-ab-evaluation.md`; update `wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md`, `wiki/index.md`, `wiki/log.md` via the karpathy-llm-wiki skill.

- [ ] **Step 1:** Start `sh eval/gate-ab/campaign.sh` in the background (`run_in_background`, long timeout), log at `~/gate-eval/campaign.log`. Expected duration: up to 48 × 45 min; check progress from `campaign.log` every 30–60 minutes; after the first 4 scored runs, report cost per run to the human — the spec allows stopping early on cost.
- [ ] **Step 2:** On completion (or human stop), `python3 eval/gate-ab/report.py ~/gate-eval/runs`; read `summary.md`.
- [ ] **Step 3:** Spot-check: for 2 solved and 2 unsolved runs per arm, read `final.diff` and confirm the verdict matches the code (a "solved" diff that only satisfies tests by hard-coding is reported as a scorer gap, not silently accepted).
- [ ] **Step 4:** Write the raw measurement file (Source/Collected/Published header; the summary.md tables verbatim; commit ids; cost totals) and update the wiki (roadmap: a new section "Measured: gated vs ungated" under item 1 or the Kit status, index row, log line); run `python3 ~/.claude/skills/karpathy-llm-wiki/scripts/check_evidence.py . wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md` → 0 suspects.
- [ ] **Step 5: Commit** in scala-coding-guidelines (explicit paths) and the README pointer in scala-llm-template.
