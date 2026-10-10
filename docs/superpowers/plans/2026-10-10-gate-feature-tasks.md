# Gate on Feature Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure ungated vs gated-full vs gated-safety on 4 feature-from-request (FR) tasks in skreeep2 6bf6c1b, counting unsolved runs and regressions.

**Architecture:** Extend `eval/gate-ab` with arms `gf`/`gs` (current template engine installed into the run copy, turn-end mode committed) and FR tasks (no cut, authored hidden spec, a reference patch used only in validation). `score.py` already scores hidden spec + regressions + holdout; it gains a regression count. Then run the screen and, if any task is kept, the same-day test phase.

**Tech Stack:** POSIX sh, Python 3, Mill, Scala 3 + weaver (skreeep2), headless `claude -p` sonnet.

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-10-gate-feature-tasks-design.md`

## Global Constraints

- skreeep2 and skreeep2-holdout are read-only; read via `git -C … show 6bf6c1b:path` / `git archive`. Never write to them.
- Run root `GA_ROOT=~/gate-eval-feature`; `~/gate-eval*` results of earlier studies stay untouched.
- Arms: `u` ungated; `gf` gated, `.dsh/policy/turn-end.tsv` mode `full`; `gs` gated, mode `safety`.
- Screen: 4 FR tasks × `u` × reps 1,2 = 8 runs. Keep a task if ungated solved ≤ 1 of 2.
- Test (same day): kept tasks (at most 3) × `gf gs u` × reps 3,4 = at most 18 runs. Screen runs not counted.
- Decision rule per gated arm, n = 2 × kept: arm solved − `u` solved ≥ n/2 → "pays"; ≤ 0 → "no gain"; else "unclear". No task kept → "ungated sonnet handles feature requests at this size".
- Each hidden-spec test ties to a request sentence. Hidden specs and reference patches live only in `eval/gate-ab/tasks/<task>/`.
- Commits end with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`; no Co-Authored-By. Explicit `git add` paths only.

## Review Focus

- A gated run copy whose engine install leaves untracked `.dsh/engine` files: the agent's `final.diff` would show the whole engine as the agent's edit — the commit before `git tag base` must include `.dsh`.
- `turn-end.tsv` mode not committed: the frozen post-hoc check blocks every turn-end in `gf`/`gs` — Task 2's test asserts a clean `git status` after install.
- A reference patch that does not apply to HEAD (whitespace/path drift): prepare must fail loudly, not record `hidden_passes_on_head=no` silently — Task 3 checks `git apply --check` first.
- `Notes[V]()` default call: Scala 3 needs `()` before a `using` list; the reference patch must update all four callers or validation's all-modules run fails.
- Floating pan values (3 × 0.05 ≠ 0.15 exactly): the hidden spec compares with a tolerance, never `==` on the pan.

---

### Task 1: Arms `gf` and `gs` in lib.sh and campaign.sh

**Files:**
- Modify: `eval/gate-ab/lib.sh` (`ga_run_id`, `GA_ALL_TASKS`)
- Modify: `eval/gate-ab/campaign.sh` (GA_ARMS validation)
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Produces: `ga_run_id <task> <g|u|t|gf|gs> <rep>`; FR task names `fr-pan fr-tuning fr-mode-leds fr-exclusive-solo` in `GA_ALL_TASKS`.

- [ ] **Step 1: Write the failing tests** — append to the `# --- lib.sh` block of `tests/shell-test.sh`:

```sh
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan gf 1")
check "run id arm gf" "$out" "fr-pan-gf-1"
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan gs 2")
check "run id arm gs" "$out" "fr-pan-gs-2"
out=$($SH -c ". '$ga/lib.sh'; case \" \$GA_ALL_TASKS \" in *' fr-exclusive-solo '*) echo yes;; *) echo no;; esac")
check "FR tasks known" "$out" "yes"
GA_ROOT=$(mktemp -d) GA_CAFFEINATED=1 GA_ARMS="gf x" $SH "$ga/campaign.sh" >/dev/null 2>&1; check "campaign rejects arm x beside gf" "$?" "1"
```

- [ ] **Step 2: Run** `sh eval/gate-ab/tests/shell-test.sh 2>&1 | grep -E 'FAIL|gf|gs|FR'` — Expected: FAIL on "run id arm gf", "run id arm gs", "FR tasks known".

- [ ] **Step 3: Implement.** In `lib.sh`:

```sh
GA_ALL_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth adsr sine by-offset sines-gen fr-pan fr-tuning fr-mode-leds fr-exclusive-solo"
```
and in `ga_run_id`: `case $2 in g|u|t|gf|gs) ;; *) ga_die "arm must be g, u, t, gf or gs, got $2" ;; esac`.
In `campaign.sh`: `for a in $arms; do case $a in g|u|t|gf|gs) ;; *) ga_die "GA_ARMS: invalid arm '$a' (want g, u, t, gf or gs)" ;; esac; done`.

- [ ] **Step 4: Run** the whole `sh eval/gate-ab/tests/shell-test.sh` — Expected: all ok, 0 FAIL.

- [ ] **Step 5: Commit** `git add eval/gate-ab/lib.sh eval/gate-ab/campaign.sh eval/gate-ab/tests/shell-test.sh` — message `gate-ab: arms gf and gs, FR task names`.

### Task 2: Engine install and turn-end mode in gated run copies

**Files:**
- Modify: `eval/gate-ab/lib.sh` (new `ga_install_engine`)
- Modify: `eval/gate-ab/run.sh` (call it for `gf`/`gs`; commit `.dsh` before `git tag base`)
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Produces: `ga_install_engine <repo-dir> <full|safety>` → exit 0; repo has the template engine at `.dsh/engine`, `.dsh/policy/turn-end.tsv` = `mode<TAB><mode>`, a frozen-paths row for it, everything committed. `GA_TEMPLATE` (default: two levels above `GA_HOME`).

- [ ] **Step 1: Failing test** — append:

```sh
# --- ga_install_engine
r=$(mktemp -d); ( cd "$r" && git init -q && mkdir .dsh && printf 'build.mill\tbuild\n' > .dsh/frozen-paths && echo x > f && git add -A && git -c user.name=t -c user.email=t@l commit -qm b )
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' safety" >/dev/null 2>&1; check "install engine exit" "$?" "0"
check "engine vendored" "$([ -f "$r/.dsh/engine/gate.sh" ] && echo y)" "y"
check "mode safety" "$(awk -F'\t' '$1=="mode"{print $2}' "$r/.dsh/policy/turn-end.tsv")" "safety"
check "mode frozen" "$(grep -c '^\.dsh/policy/turn-end\.tsv	' "$r/.dsh/frozen-paths")" "1"
check "install committed" "$(git -C "$r" status --porcelain | wc -l | tr -d ' ')" "0"
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' full" >/dev/null 2>&1
check "mode full replaces" "$(awk -F'\t' '$1=="mode"{print $2}' "$r/.dsh/policy/turn-end.tsv")" "full"
check "frozen row once" "$(grep -c '^\.dsh/policy/turn-end\.tsv	' "$r/.dsh/frozen-paths")" "1"
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' fast" >/dev/null 2>&1; check "install rejects mode fast" "$?" "1"
rm -rf "$r"
```

- [ ] **Step 2: Run** shell-test — Expected: FAIL "install engine exit" (`ga_install_engine: not found`).

- [ ] **Step 3: Implement** in `lib.sh`:

```sh
GA_TEMPLATE=${GA_TEMPLATE:-$(CDPATH= cd -- "$GA_HOME/../.." 2>/dev/null && pwd)}

# Gated arms gf/gs (spec 2026-10-10 §5): the current template engine in the run copy, the arm's turn-end mode frozen and committed.
ga_install_engine() {
  case $2 in full|safety) ;; *) ga_die "turn-end mode must be full or safety, got $2" ;; esac
  sh "$GA_TEMPLATE/kit/harness/install.sh" "$1" >/dev/null || ga_die "engine install into $1 failed"
  printf '# gate-eval arm\nmode\t%s\n' "$2" > "$1/.dsh/policy/turn-end.tsv"
  grep -q '^\.dsh/policy/turn-end\.tsv	' "$1/.dsh/frozen-paths" 2>/dev/null ||
    printf '.dsh/policy/turn-end.tsv\tthe turn-end mode is the human'"'"'s\n' >> "$1/.dsh/frozen-paths"
  ( cd "$1" && git add .dsh && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm "engine, turn-end mode $2" ) ||
    ga_die "commit engine in $1 failed"
}
```

In `run.sh`, after the `if [ "$arm" = t ]` block and before the contract `sed`:

```sh
  case $arm in gf) ga_install_engine "$rd/repo" full ;; gs) ga_install_engine "$rd/repo" safety ;; esac
```

- [ ] **Step 4: Run** shell-test — Expected: 0 FAIL.

- [ ] **Step 5: Commit** lib.sh, run.sh, tests/shell-test.sh — `gate-ab: gf/gs install the template engine and commit the turn-end mode`.

### Task 3: FR validation with a reference patch (prepare.sh)

**Files:**
- Modify: `eval/gate-ab/prepare.sh`
- Modify: `eval/gate-ab/campaign.sh` (validation line count: 3, or 4 for GATE_VISIBLE or REFERENCE_PATCH)
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Consumes: `task.env` `REFERENCE_PATCH` (path inside the task folder), `HIDDEN_SPEC_SRC`, `CUT_FILES=''`.
- Produces: `validation.txt` lines `cut_compiles` (HEAD compiles), `hidden_fails_on_cut` (hidden fails on HEAD), `hidden_passes_on_head` (hidden passes on HEAD + patch), `reference_passes_all` (every test module `-k` and the holdout pass on HEAD + patch).

- [ ] **Step 1: Failing test** — prepare must refuse a non-applying patch before any Mill call:

```sh
# --- prepare.sh: reference patch that does not apply
fr=$(mktemp -d); mkdir -p "$fr/tasks/fr-x/hidden/a" "$fr/head"
printf "TASK_MODULE='a.test'\nHIDDEN_SPEC='a/S.scala'\nHIDDEN_SPEC_SRC='hidden/a/S.scala'\nCUT_FILES=''\nREFERENCE_PATCH='reference.patch'\nFEATURE='x'\n" > "$fr/tasks/fr-x/task.env"
echo 'object S extends Suite' > "$fr/tasks/fr-x/hidden/a/S.scala"
printf -- '--- a/nope.scala\n+++ b/nope.scala\n@@ -1 +1 @@\n-a\n+b\n' > "$fr/tasks/fr-x/reference.patch"
out=$($SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; GA_HOME='$fr'; REFERENCE_PATCH=reference.patch; ga_check_patch fr-x '$fr/head'" 2>&1); rc=$?
check "non-applying reference patch refused" "$rc" "1"
case $out in *"does not apply"*) ok "patch refusal names the cause" ;; *) bad "patch refusal names the cause" "$out" ;; esac
rm -rf "$fr"
```

- [ ] **Step 2: Run** — Expected: FAIL (`ga_check_patch: not found`).

- [ ] **Step 3: Implement.** In `lib.sh`:

```sh
# FR tasks: the reference patch must apply to <dir> (a HEAD copy) before any Mill run.
ga_check_patch() {
  p=$GA_HOME/tasks/$1/$REFERENCE_PATCH
  [ -f "$p" ] || ga_die "reference patch $p missing"
  git -C "$2" apply --check "$p" 2>/dev/null || ga_die "reference patch $p does not apply to $2"
}
```

In `prepare.sh`: initialise `REFERENCE_PATCH=` next to `HIDDEN_SPEC_SRC=; GATE_VISIBLE=`. In the `HIDDEN_SPEC_SRC` head-validate branch, after `cp -R "$h" "$hv"; rm -rf "$hv/out"`:

```sh
  if [ -n "${REFERENCE_PATCH:-}" ]; then
    ( cd "$hv" && git init -q ) ; ga_check_patch "$task" "$hv"
    git -C "$hv" apply "$GA_HOME/tasks/$task/$REFERENCE_PATCH" || ga_die "apply reference patch"
  fi
```

and after the `mill_in 1800 "$hv" "$TASK_MODULE"` line, before `rm -rf "$hv"`:

```sh
  r=
  if [ -n "${REFERENCE_PATCH:-}" ]; then
    # Spec 2026-10-10 §3: with the reference applied, every existing test module and the holdout pass.
    mods=$(python3 -c 'import json,sys;print(" + ".join(sorted(json.load(open(sys.argv[1]))["modules"])))' "$GA_ROOT/head-baseline.json") || ga_die "read head-baseline.json"
    ho=$base/holdout-ref; rm -rf "$ho"; mkdir -p "$ho"
    git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | tar -x -C "$ho" || ga_die "holdout export"
    hod=$(CDPATH= cd -- "$ho" && pwd -P)
    # shellcheck disable=SC2086
    mill_in 1800 "$hv" -k $mods > "$base/reference-all.log" 2>&1 && ( export DSH_HOLDOUT_DIR="$hod"; mill_in 600 "$hv" holdout.test ) >> "$base/reference-all.log" 2>&1 && r=yes || r=no
    rm -rf "$ho"
  fi
```

and append `[ -z "$r" ] || printf 'reference_passes_all=%s\n' "$r" >> "$base/validation.txt"` after the gate_visible line; final check `[ "$c$f$p" = yesyesyes ] && [ "${g:-yes}" = yes ] && [ "${r:-yes}" = yes ]`. (`r` is set to empty before the `if [ -n "${HIDDEN_SPEC_SRC:-}" ]` branch so non-FR tasks write no line.) `campaign.sh`'s 3-or-4-lines check already accepts 4 lines.

Note: `bench.test` and `backend.opencl.test` are in head-baseline's module list only if HEAD passes them; the baseline file is authoritative, as in the gate-visible check.

- [ ] **Step 4: Run** shell-test — Expected: 0 FAIL.

- [ ] **Step 5: Commit** lib.sh, prepare.sh, tests/shell-test.sh — `gate-ab: FR tasks validate a reference patch against all modules and the holdout`.

### Task 4: Regression count in score.json

**Files:**
- Modify: `eval/gate-ab/score.py` (pure `regression_count`, fields `holdout_failed`, `regression_count`)
- Test: `eval/gate-ab/tests/test_score.py`

**Interfaces:**
- Produces: `score.json` keys `holdout_failed` (int, weaver failed count of the holdout run) and `regression_count` (int: regressions entries not starting with `<`, plus `holdout_failed`; `-1` when regressions holds a `<…>` marker, meaning "not countable").

- [ ] **Step 1: Failing test** in `tests/test_score.py` (same `unittest.TestCase` style as its other classes):

```python
class RegressionCountTest(unittest.TestCase):
    def test_counts_entries_and_holdout(self):
        self.assertEqual(score.regression_count(["control.test", "app.test"], 2), 4)

    def test_clean(self):
        self.assertEqual(score.regression_count([], 0), 0)

    def test_marker_is_uncountable(self):
        self.assertEqual(score.regression_count(["<build>"], 0), -1)
        self.assertEqual(score.regression_count(["app.test", "<tests did not run>"], 1), -1)
```

- [ ] **Step 2: Run** `python3 -m unittest eval/gate-ab/tests/test_score.py -k RegressionCount` — Expected: FAIL `AttributeError: … 'regression_count'`.

- [ ] **Step 3: Implement** next to `is_solved`:

```python
def regression_count(regressions, holdout_failed):
    """Spec 2026-10-10 §4: failing regression entries plus failing holdout tests; -1 when a `<…>` marker makes it uncountable."""
    if any(r.startswith("<") for r in regressions):
        return -1
    return len(regressions) + holdout_failed
```

In `main`: add `holdout_failed=0, regression_count=0` to the initial `rec`; after `rec["holdout_passed"] = …` set `rec["holdout_failed"] = hf`; just before `rec["solved"] = …` set `rec["regression_count"] = regression_count(rec["regressions"], rec["holdout_failed"])`.

- [ ] **Step 4: Run** `python3 -m unittest discover -s eval/gate-ab/tests -p 'test_*.py'` — Expected: OK.

- [ ] **Step 5: Commit** score.py, tests/test_score.py — `gate-ab: score.json counts regressions and failing holdout tests`.

### Task 5: Run root and engine smoke

**Files:** none in the repo (run root setup only).

- [ ] **Step 1:** `mkdir -p ~/gate-eval-feature && cp -R ~/gate-eval/head ~/gate-eval-feature/head && cp ~/gate-eval/head-baseline.json ~/gate-eval-feature/` — HEAD and baseline are the same commit 6bf6c1b. Expected: both present.
- [ ] **Step 2:** Engine smoke per mode on a scratch copy: `s=$(mktemp -d); git -C /Users/viktorskalinins/IdeaProjects/skreeep2 archive 6bf6c1b | tar -x -C "$s"; (cd "$s" && git init -q && git add -A && git -c user.name=t -c user.email=t@l commit -qm b); GA_ROOT=~/gate-eval-feature GA_LIB_PATH=$PWD/eval/gate-ab/lib.sh sh -c '. "$GA_LIB_PATH"; ga_install_engine "$0" safety' "$s"; (cd "$s" && sh .dsh/engine/gate.sh health; echo '{}' | sh .dsh/engine/gate.sh turn-end; echo rc=$?)`, then the same with `full`.
  Expected: health prints no FAIL caused by the engine install; turn-end `rc=0` in both modes (no edits → nothing to check). Any block here is fixed in the harness (ledger a Ruling) before Task 10.

### Task 6: FR task `fr-pan`

**Files (all under `eval/gate-ab/tasks/fr-pan/`):** `task.env`, `prompt.txt`, `hidden/control/test/src/com/github/mercurievv/skreeep2/control/PanSpec.scala`, `reference.patch`.

- [ ] **Step 1: task.env**

```sh
TASK_MODULE='control.test'
HIDDEN_SPEC='control/test/src/com/github/mercurievv/skreeep2/control/PanSpec.scala'
HIDDEN_SPEC_SRC='hidden/control/test/src/com/github/mercurievv/skreeep2/control/PanSpec.scala'
REFERENCE_PATCH='reference.patch'
CUT_FILES=''
FEATURE='pan from the V-Pot in MixerMode'
```

- [ ] **Step 2: prompt.txt** (sentences numbered here only for the spec mapping; the file has no numbers)

```
Add panning to the mixer. (1) Turning a strip's V-Pot (Control.Encoder) in MixerMode pans that strip's instrument: each detent moves the pan by 0.05, pan starts at 0.0 (centre) and is clamped to -1.0 .. 1.0. (2) MixerMode emits the new command Command.SetPan(instrument: String, pan: Double) only when the pan actually changed, and turning a V-Pot never changes a level. (3) Everything else keeps working as it does today. Stop when you are done.
```

- [ ] **Step 3: hidden spec**

```scala
package com.github.mercurievv.skreeep2.control

import weaver.*

object PanSpec extends SimpleIOSuite:

  private val mode = new MixerMode(Vector("kick", "snare"), 2)

  private def pans(cs: List[Command]): List[(String, Double)] = cs.collect { case Command.SetPan(i, p) => (i, p) }

  // (1)(2): 3 detents from centre → 0.15, as SetPan only
  pureTest("a V-Pot turn pans its strip's instrument by 0.05 per detent") {
    val (_, cs, _) = mode.step(mode.initial, Control.Encoder(0, 3))
    val ps = pans(cs)
    expect(ps.size == 1) and expect(cs.size == 1) and expect(ps.headOption.exists((i, p) => i == "kick" && math.abs(p - 0.15) < 1e-9))
  }

  // (1): negative detents pan left, on the strip turned
  pureTest("turning left pans left") {
    val ps = pans(mode.step(mode.initial, Control.Encoder(1, -4))._2)
    expect(ps.headOption.exists((i, p) => i == "snare" && math.abs(p + 0.2) < 1e-9))
  }

  // (1)(2): clamped at 1.0; a turn past the end changes nothing, so no command
  pureTest("pan is clamped to -1 .. 1 and a turn that changes nothing emits nothing") {
    val (s1, c1, _) = mode.step(mode.initial, Control.Encoder(0, 40))
    val (_, c2, _) = mode.step(s1, Control.Encoder(0, 5))
    expect(pans(c1).headOption.exists((_, p) => math.abs(p - 1.0) < 1e-9)) and expect(c2.isEmpty)
  }

  // (2): a V-Pot never changes a level; a fader still emits SetLevel only
  pureTest("pan and level stay separate") {
    val (s1, _, _) = mode.step(mode.initial, Control.Encoder(0, 2))
    val (_, cs, _) = mode.step(s1, Control.Fader(0, 0.5))
    expect(cs == List(Command.SetLevel("kick", 0.5)))
  }

  // (1): pan accumulates across turns
  pureTest("turns accumulate") {
    val (s1, _, _) = mode.step(mode.initial, Control.Encoder(0, 2))
    val ps = pans(mode.step(s1, Control.Encoder(0, -6))._2)
    expect(ps.headOption.exists((_, p) => math.abs(p + 0.2) < 1e-9))
  }
```

- [ ] **Step 4: reference patch.** In a scratch HEAD copy (`r=$(mktemp -d); git -C ~/IdeaProjects/skreeep2 archive 6bf6c1b | tar -x -C "$r"; cd "$r"; git init -q; git add -A; git commit -qm b`) make these edits, then `git diff > …/tasks/fr-pan/reference.patch`:
  - `Command.scala`: add `/** An instrument's pan, -1.0 (left) .. 1.0 (right), absolute like a level. */ case SetPan(instrument: String, pan: Double)`.
  - `MixerMode.scala`: `Mixer` gains `pans: Map[String, Double]` (initial `Map.empty`); new case before `case _`:
    ```scala
      case Control.Encoder(strip, delta) =>
        visible(state, strip).fold(quiet(state)) { name =>
          val before = state.pans.getOrElse(name, 0.0)
          val now = math.max(-1.0, math.min(1.0, before + delta * 0.05))
          if now == before then quiet(state)
          else (state.copy(pans = state.pans.updated(name, now)), List(Command.SetPan(name, now)), Nil)
        }
    ```
    and `initial = Mixer(strips.map(_ -> 1.0).toMap, Set.empty, Set.empty, 0, Map.empty)`.
  - `MixerSurface.scala` `apply`: `case (acc, Command.SetLevel(instrument, level)) => acc.updated(instrument, level); case (acc, Command.SetPan(_, _)) => acc` (no engine reads pan yet).

- [ ] **Step 5: validate** `GA_ROOT=~/gate-eval-feature sh eval/gate-ab/prepare.sh fr-pan` — Expected: four lines `=yes`. If not: fix the reference/spec only where they contradict the prompt; a feature that cannot validate is replaced (ledger Ruling).

- [ ] **Step 6: Commit** the task folder — `gate-ab: FR task fr-pan`.

### Task 7: FR task `fr-tuning`

**Files (under `eval/gate-ab/tasks/fr-tuning/`):** `task.env`, `prompt.txt`, `hidden/app/test/src/com/github/mercurievv/skreeep2/TuningSpec.scala`, `reference.patch`.

- [ ] **Step 1: task.env**

```sh
TASK_MODULE='app.test'
HIDDEN_SPEC='app/test/src/com/github/mercurievv/skreeep2/TuningSpec.scala'
HIDDEN_SPEC_SRC='hidden/app/test/src/com/github/mercurievv/skreeep2/TuningSpec.scala'
REFERENCE_PATCH='reference.patch'
CUT_FILES=''
FEATURE='a reference pitch for Notes'
```

- [ ] **Step 2: prompt.txt**

```
Let a song choose its tuning reference. (1) Notes takes the A4 reference pitch in Hz as a constructor parameter: final class Notes[V](a4: Double = 440.0)(using ConvertableTo[V], Field[V]), so Notes[Double](432.0) tunes everything to A4 = 432 Hz and Notes[Double]() keeps 440. (2) Every pitch Notes gives — pitch, justPitch and the note names — scales with the reference. (3) Existing songs keep sounding exactly as they do now. Stop when you are done.
```

- [ ] **Step 3: hidden spec**

```scala
package com.github.mercurievv.skreeep2

import weaver.*
import spire.implicits.*

import com.github.mercurievv.skreeep2.score.Notes

object TuningSpec extends SimpleIOSuite:

  private def near(a: Double, b: Double) = math.abs(a - b) < 1e-9

  // (1): default keeps 440 → A three octaves below = 55
  pureTest("the default reference is A4 = 440") {
    expect(near(Notes[Double]().A, 55.0))
  }

  // (1)(2): 432 → A = 54, pitch(12) = 108
  pureTest("a 432 reference scales pitch") {
    val n = Notes[Double](432.0)
    expect(near(n.A, 54.0)) and expect(near(n.pitch(12), 108.0))
  }

  // (2): just intonation fifth = 3/2 of the reference A
  pureTest("justPitch scales with the reference") {
    expect(near(Notes[Double](432.0).justPitch(7), 81.0))
  }

  // (2): note names follow (C = pitch(-9))
  pureTest("note names scale with the reference") {
    val ratio = Notes[Double](432.0).C / Notes[Double]().C
    expect(near(ratio, 432.0 / 440.0))
  }
```

- [ ] **Step 4: reference patch** (same scratch-copy procedure as Task 6):
  - `Notes.scala`: `final class Notes[V](a4: Double = 440.0)(using convert: ConvertableTo[V], field: Field[V])`; `lazy val f0: V = convert.fromDouble(a4 / 8)`; scaladoc of `f0`: "Reference pitch: A, three octaves below `a4`."; class doc example `Notes[V]()`.
  - Callers `song/.../Modulated.scala:95`, `Song.scala:72`, `Song.scala:146`: `Notes[V]()(using convert, field)`; `TemperamentCompare.scala:18`: `Notes[V]()(using a.convert, a.field)`.

- [ ] **Step 5: validate** `GA_ROOT=~/gate-eval-feature sh eval/gate-ab/prepare.sh fr-tuning` — Expected: four `=yes` lines.
- [ ] **Step 6: Commit** — `gate-ab: FR task fr-tuning`.

### Task 8: FR task `fr-mode-leds`

**Files (under `eval/gate-ab/tasks/fr-mode-leds/`):** `task.env`, `prompt.txt`, `hidden/control/test/src/com/github/mercurievv/skreeep2/control/ModeLedsSpec.scala`, `reference.patch`.

- [ ] **Step 1: task.env** — as Task 6 with `HIDDEN_SPEC='control/test/src/com/github/mercurievv/skreeep2/control/ModeLedsSpec.scala'`, matching `HIDDEN_SPEC_SRC='hidden/…/ModeLedsSpec.scala'`, `FEATURE='mode-key lamps for Modes.switching'`.

- [ ] **Step 2: prompt.txt**

```
Show which mode is current on the desk. (1) Modes.switching lights the mode keys: its enter output also contains Feedback.Led(Button.ModeKey(i), i == current) for every mode index i. (2) Switching modes repaints those lamps too. (3) Modes.single and everything else keep behaving as today. Stop when you are done.
```

- [ ] **Step 3: hidden spec**

```scala
package com.github.mercurievv.skreeep2.control

import weaver.*

object ModeLedsSpec extends SimpleIOSuite:

  private val a = new MixerMode(Vector("kick"), 1)
  private val b = new MixerMode(Vector("pad"), 1)
  private val modes = Modes.switching(Vector(a, b))

  // (1)
  pureTest("entering lights the current mode's key and darkens the others") {
    val fb = modes.enter(modes.initial)
    expect(fb.contains(Feedback.Led(Button.ModeKey(0), true))) and expect(fb.contains(Feedback.Led(Button.ModeKey(1), false)))
  }

  // (2)
  pureTest("a switch repaints the mode keys") {
    val (_, _, fb) = modes.step(modes.initial, Control.Press(Button.ModeKey(1), true))
    expect(fb.contains(Feedback.Led(Button.ModeKey(1), true))) and expect(fb.contains(Feedback.Led(Button.ModeKey(0), false)))
  }

  // (1): one lamp per mode, no more
  pureTest("one mode-key lamp per mode") {
    val keys = modes.enter(modes.initial).collect { case Feedback.Led(Button.ModeKey(i), _) => i }
    expect(keys.sorted == List(0, 1))
  }

  // (3)
  pureTest("single lights no mode key") {
    expect(!Modes.single(a).enter(a.initial).exists { case Feedback.Led(Button.ModeKey(_), _) => true; case _ => false })
  }
```

- [ ] **Step 4: reference patch** — in `Modes.switching`:
  ```scala
      def enter(state: Switching): List[Feedback] =
        state.held.lift(state.current).toList.flatMap(h => h.mode.enter(h.state)) ++
          modes.indices.toList.map(i => Feedback.Led(Button.ModeKey(i), i == state.current))
  ```
  (the switch branch already returns `enter(next)`).
- [ ] **Step 5: validate** — four `=yes` lines.
- [ ] **Step 6: Commit** — `gate-ab: FR task fr-mode-leds`.

### Task 9: FR task `fr-exclusive-solo`

**Files (under `eval/gate-ab/tasks/fr-exclusive-solo/`):** `task.env`, `prompt.txt`, `hidden/control/test/src/com/github/mercurievv/skreeep2/control/ExclusiveSoloSpec.scala`, `reference.patch`.

- [ ] **Step 1: task.env** — as Task 6 with `ExclusiveSoloSpec.scala` paths, `FEATURE='exclusive solo in MixerMode'`.

- [ ] **Step 2: prompt.txt**

```
Add exclusive solo to the mixer. (1) MixerMode takes a new option: new MixerMode(strips, perBank, exclusiveSolo = true); it defaults to false. (2) With it on, soloing an instrument clears every other solo, and the solo lamps of visible strips whose solo was cleared go dark. (3) Pressing the solo of the only soloed instrument un-solos it, as today. (4) With the option off, the mixer behaves exactly as today. Stop when you are done.
```

- [ ] **Step 3: hidden spec**

```scala
package com.github.mercurievv.skreeep2.control

import weaver.*

object ExclusiveSoloSpec extends SimpleIOSuite:

  private val band = Vector("kick", "snare", "bass")

  private def run(mode: MixerMode, cs: List[Control]) =
    cs.foldLeft((mode.initial, List.empty[Command], List.empty[Feedback])) { case ((s, _, _), c) => mode.step(s, c) }

  private val excl = new MixerMode(band, 3, exclusiveSolo = true)

  // (2): solo kick, then solo snare → kick down, snare up; kick's lamp dark
  pureTest("a second solo replaces the first") {
    val (_, cs, fb) = run(excl, List(Control.Press(Button.Solo(0), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("kick", 0.0), Command.SetLevel("snare", 1.0))) and
      expect(fb.contains(Feedback.Led(Button.Solo(0), false))) and expect(fb.contains(Feedback.Led(Button.Solo(1), true)))
  }

  // (3)
  pureTest("pressing the only solo again un-solos it") {
    val (_, cs, _) = run(excl, List(Control.Press(Button.Solo(1), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("kick", 1.0), Command.SetLevel("bass", 1.0)))
  }

  // (1)(4): default off — solos add up
  pureTest("without the option solos add up") {
    val (_, cs, _) = run(new MixerMode(band, 3), List(Control.Press(Button.Solo(0), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("snare", 1.0)))
  }
```

- [ ] **Step 4: reference patch** — `final class MixerMode(strips: Vector[String], perBank: Int, exclusiveSolo: Boolean = false) extends Mode:`; the Solo case becomes:
  ```scala
      case Control.Press(Button.Solo(strip), true) =>
        visible(state, strip).fold(quiet(state)) { name =>
          val cleared = if exclusiveSolo && !state.soloed(name) then state.soloed else Set.empty[String]
          val next = state.copy(soloed = toggle(state.soloed -- cleared, name))
          val dark = (0 until perBank).toList.flatMap(s => visible(state, s).filter(cleared).map(_ => Feedback.Led(Button.Solo(s), false)))
          changed(state, next, dark :+ Feedback.Led(Button.Solo(strip), next.soloed(name)))
        }
  ```
- [ ] **Step 5: validate** — four `=yes` lines.
- [ ] **Step 6: Commit** — `gate-ab: FR task fr-exclusive-solo`.

### Task 10: Screen (8 ungated runs)

- [ ] **Step 1:** Write `~/gate-eval-feature/RULE.md` with the Global Constraints' screen rule, test-phase rule and decision rule verbatim, before any run.
- [ ] **Step 2:** `GA_ROOT=~/gate-eval-feature GA_TASKS="fr-pan fr-tuning fr-mode-leds fr-exclusive-solo" GA_ARMS=u GA_REPS="1 2" sh eval/gate-ab/campaign.sh` (background; earlier run roots stay unreadable during the campaign: `chmod 000 ~/gate-eval ~/gate-eval-hard ~/gate-eval-control`, restore 755 after).
  Expected: 8 lines in `campaign.log`, each with a `solved=` value; 0 `score.json` errors.
- [ ] **Step 3:** Audit contamination flags as in earlier studies (read the flagged transcript lines; clear only tripwire false positives, ledger each). Tabulate per run: solved, regression_count, holdout_failed, wall, cost.
- [ ] **Step 4:** Apply the screen rule; write the kept set to `~/gate-eval-feature/KEPT`.

### Task 11: Test phase (only if KEPT is non-empty)

- [ ] **Step 1:** Same day: `GA_TASKS="<kept>" GA_ARMS="gf gs u" GA_REPS="3 4" sh eval/gate-ab/campaign.sh`. Expected: 6 × kept runs, 0 errors.
- [ ] **Step 2:** Audit as Task 10 Step 3. Per arm: solved, regressions (sum of `regression_count`, `-1` reported separately), `false_done`, `gate_blocks` kinds, median wall, median cost. Apply the decision rule for `gf` and `gs` against `u`; report `gf` − `gs`.

### Task 12: Write-up (scala-coding-guidelines, karpathy-llm-wiki skill)

- [ ] **Step 1:** Raw file `raw/llm-scala-fusion/2026-10-10-local-gate-feature-requests.md` (or the run date) in the format of `2026-10-09-local-gate-visible-tasks-screen.md`: source line with template commit, Why, Tasks (each request), Validation, Screen table, Test table if run, Verdict, Limits. Numbers outside fenced blocks.
- [ ] **Step 2:** Update roadmap item 11 (and, if `gf` pays and `gs` does not, the safety-default block) in `wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md`; index and log; `python3 ~/.claude/skills/karpathy-llm-wiki/scripts/check_evidence.py .` → no new suspects.
- [ ] **Step 3:** Commit the raw and wiki files by explicit path.
