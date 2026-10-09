# Gate-Visible Tasks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 4 remove-and-rebuild tasks (adsr, sine, by-offset, sines-gen) whose wrong rebuilds the gate can see, with hidden specs written for this study, and a validation step proving the gate can see them.

**Architecture:** `eval/gate-ab/` gains: an optional `HIDDEN_SPEC_SRC` in `task.env` (hidden spec taken from the task folder, not the exported tree); an optional `GATE_VISIBLE=1` that makes `prepare.sh` add a 4th validation line, `gate_visible_on_cut`, from running every other test module and the holdout on the cut tree; `campaign.sh` accepting 3- or 4-line all-yes validation and reps 1..4; and the 4 task folders. Campaigns themselves are operational steps the controller runs after the branch is merged (not part of the tasks).

**Tech Stack:** POSIX sh, Python 3 (unittest), Mill, Scala 3 + weaver (hidden specs, compiled inside skreeep2's exported tree).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-09-gate-visible-tasks-design.md`

## Global Constraints

- skreeep2 (`/Users/viktorskalinins/IdeaProjects/skreeep2`) and skreeep2-holdout are read only. Read skreeep2 code with `git -C … show 6bf6c1b:<path>`; never write there.
- Hidden specs live in `eval/gate-ab/tasks/<task>/hidden/<HIDDEN_SPEC path>`, never in skreeep2.
- Hidden specs check only behaviour the cut members' scaladoc (or the class scaladoc) states; each test carries a comment quoting the scaladoc phrase it comes from.
- Cut: bodies of the named members become `???`; signatures, scaladoc and every other line unchanged.
- Existing 8 tasks and their validation stay valid without re-preparing: a 3-line all-yes `validation.txt` is still "prepared".
- Commits: never add a `Co-Authored-By` trailer; end every commit message with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`. Stage explicit paths only.
- Tests: `cd eval/gate-ab/tests && sh shell-test.sh` and `python3 -m unittest -q test_report test_timeout test_score` (run from inside `tests/`; test_score takes about 100 s).

## Review Focus

- A task with `GATE_VISIBLE` unset must produce exactly the old 3-line `validation.txt` (shell test "prepare validation" pins it).
- `HIDDEN_SPEC_SRC` set but the file missing in the task folder → `prepare.sh` dies naming the path, no partial base left looking prepared (test added in Task 1).
- `HIDDEN_SPEC_SRC` set and a file already exists at `$HIDDEN_SPEC` in the exported tree → die (an authored spec must not shadow a real one) (test in Task 1).
- `gate_visible_on_cut=no` → `prepare.sh` exits non-zero and campaign preflight treats the task as unprepared (test in Task 1).
- Hidden spec passes on HEAD but would also pass on a trivially wrong rebuild (e.g. ADSR returning sustainLevel everywhere) → each spec includes at least one boundary test that such a rebuild fails (Task 2/3 checklists).

---

### Task 1: Harness — authored hidden specs, gate-visible validation, reps 1..4

**Files:**
- Modify: `eval/gate-ab/prepare.sh`
- Modify: `eval/gate-ab/campaign.sh` (validation check line ~61, GA_REPS check line ~39)
- Modify: `eval/gate-ab/lib.sh:10` (GA_ALL_TASKS)
- Test: `eval/gate-ab/tests/shell-test.sh` (prepare section ~61–86, campaign GA_REPS tests)

**Interfaces:**
- Produces: `task.env` keys `HIDDEN_SPEC_SRC` (optional, path relative to the task folder) and `GATE_VISIBLE` (optional, `1` to enable); `validation.txt` 4th line `gate_visible_on_cut=yes|no`; `base/<task>/gate-visible.log`; `GA_ALL_TASKS` includes `adsr sine by-offset sines-gen`; `GA_REPS` accepts 1..4.

- [ ] **Step 1: Write the failing shell tests**

Append to the prepare section of `tests/shell-test.sh`, after the existing `rm -rf "$tmp"` of that section, a new block (same helper style: `check`, `ok`, `bad`):

```sh
# --- prepare.sh: authored hidden spec (HIDDEN_SPEC_SRC) and gate-visible validation
tmp=$(mktemp -d)
fake=$tmp/skreeep2; mkdir -p "$fake/m/src" "$fake/d/src" "$tmp/home/tasks/t2/stub/m/src" "$tmp/home/tasks/t2/hidden/m/test/src" "$tmp/root/head" "$tmp/hsrc"
# fake mill: compile ok; on head everything passes; elsewhere m.test fails iff the hidden spec is present,
# d.test (downstream) fails iff A.scala is cut, holdout.test fails iff FAIL_HOLDOUT is set.
cat >"$fake/mill" <<'MILL'
#!/bin/sh
case $PWD in */head|*/head-validate) exit 0 ;; esac
rc=0
for a; do case $a in
  __.compile) ;;
  m.test) [ -f m/test/src/ASpec.scala ] && rc=1 ;;
  d.test) grep -q '???' m/src/A.scala && rc=1 ;;
  holdout.test) [ -n "${FAIL_HOLDOUT:-}" ] && rc=1 ;;
esac; done
exit $rc
MILL
chmod +x "$fake/mill"; cp "$fake/mill" "$tmp/root/head/mill"
echo 'object A { def f = 1 }' >"$fake/m/src/A.scala"; echo 'object D' >"$fake/d/src/D.scala"
( cd "$fake" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init )
head=$(git -C "$fake" rev-parse HEAD)
( cd "$tmp/hsrc" && echo x >x && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm h )
hhead=$(git -C "$tmp/hsrc" rev-parse HEAD)
printf '{"modules": {"m.test": true, "d.test": true}}\n' >"$tmp/root/head-baseline.json"
printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='m/test/src/ASpec.scala'\nHIDDEN_SPEC_SRC='hidden/m/test/src/ASpec.scala'\nGATE_VISIBLE=1\nCUT_FILES='m/src/A.scala'\nFEATURE='f'\n" >"$tmp/home/tasks/t2/task.env"
echo 'object A { def f = ??? }' >"$tmp/home/tasks/t2/stub/m/src/A.scala"
echo 'class ASpec' >"$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
cp "$ga/lib.sh" "$ga/timeout.py" "$ga/prepare.sh" "$tmp/home/" 2>/dev/null
penv() { GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$fake GA_COMMIT=${PC:-$head} GA_HOLDOUT_SRC=$tmp/hsrc GA_HOLDOUT_COMMIT=$hhead "$@"; }
penv $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1
check "prepare authored exit 0" "$?" "0"
check "prepare authored validation" "$(cat "$tmp/root/base/t2/validation.txt" 2>/dev/null | tr '\n' ' ')" "cut_compiles=yes hidden_fails_on_cut=yes hidden_passes_on_head=yes gate_visible_on_cut=yes "
[ -f "$tmp/root/base/t2/hidden/m/test/src/ASpec.scala" ] && [ ! -e "$tmp/root/base/t2/tree/m/test/src/ASpec.scala" ] && ok "prepare authored spec hidden" || bad "prepare authored spec hidden"
[ ! -e "$tmp/root/head/m/test/src/ASpec.scala" ] && ok "prepare leaves head untouched" || bad "prepare leaves head untouched"
# downstream does not see the cut, holdout passes -> not gate-visible -> exit 1, 4th line no
sed -i.bak 's/d.test) grep -q .??? m\/src\/A.scala. && rc=1 ;;/d.test) ;;/' "$fake/mill" && rm -f "$fake/mill.bak"
( cd "$fake" && git add -A && git -c user.name=t -c user.email=t@t commit -qm nodown )
head2=$(git -C "$fake" rev-parse HEAD)
PC=$head2 penv $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "prepare not gate-visible fails" || bad "prepare not gate-visible fails"
check "prepare not gate-visible line" "$(sed -n 4p "$tmp/root/base/t2/validation.txt" 2>/dev/null)" "gate_visible_on_cut=no"
# holdout failing alone is enough
FAIL_HOLDOUT=1 PC=$head2 penv $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1
check "prepare holdout-visible exit 0" "$?" "0"
# missing authored spec -> die
rm "$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
penv $SH "$tmp/home/prepare.sh" t2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'hidden/m/test/src/ASpec.scala' "$tmp/out" && ok "prepare missing authored spec dies" || bad "prepare missing authored spec dies"
[ ! -f "$tmp/root/base/t2/validation.txt" ] && ok "prepare missing spec leaves no validation" || bad "prepare missing spec leaves no validation"
# authored spec would shadow a real one -> die
echo 'class ASpec' >"$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
mkdir -p "$fake/m/test/src"; echo 'class ASpec' >"$fake/m/test/src/ASpec.scala"
( cd "$fake" && git add -A && git -c user.name=t -c user.email=t@t commit -qm real )
PC=$(git -C "$fake" rev-parse HEAD) penv $SH "$tmp/home/prepare.sh" t2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'already in the tree' "$tmp/out" && ok "prepare authored shadow dies" || bad "prepare authored shadow dies"
rm -rf "$tmp"
```

Also add, in the campaign section near the existing GA_REPS tests, a test that `GA_REPS=4` is accepted and `GA_REPS=5` dies, mirroring the existing invalid-rep test (grep `GA_REPS: invalid rep` in shell-test.sh for its shape), and a test that a 4-line all-yes `validation.txt` counts as prepared (no prepare call) while a 4-line file ending `gate_visible_on_cut=no` triggers prepare — mirror the existing "campaign no prepare when ready" test, writing the 4-line file into one task's `base/<task>/validation.txt`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd eval/gate-ab/tests && sh shell-test.sh 2>&1 | grep -E "^(FAIL|bad)|passed"`
Expected: the new checks fail (prepare ignores HIDDEN_SPEC_SRC: "hidden spec … not in tree"; GA_REPS=4 rejected).

- [ ] **Step 3: Implement prepare.sh**

Replace the hidden-spec line block and the validation tail of `prepare.sh`:

```sh
mkdir -p "$base/hidden/$(dirname "$HIDDEN_SPEC")"
if [ -n "${HIDDEN_SPEC_SRC:-}" ]; then
  # Authored for the study: the spec comes from the task folder; the exported tree must not already have one there.
  src=$GA_HOME/tasks/$task/$HIDDEN_SPEC_SRC
  [ -f "$src" ] || { rm -rf "$base"; ga_die "authored hidden spec $src missing"; }
  [ ! -e "$base/tree/$HIDDEN_SPEC" ] || { rm -rf "$base"; ga_die "hidden spec $HIDDEN_SPEC already in the tree; HIDDEN_SPEC_SRC would shadow it"; }
  cp "$src" "$base/hidden/$HIDDEN_SPEC" || ga_die "copy $src"
else
  mv "$base/tree/$HIDDEN_SPEC" "$base/hidden/$HIDDEN_SPEC" || ga_die "hidden spec $HIDDEN_SPEC not in tree"
fi
```

`task.env` is sourced by `ga_task_env`; make sure `HIDDEN_SPEC_SRC` and `GATE_VISIBLE` from a previous task cannot leak: at the top of `prepare.sh`, before `ga_task_env "$task"`, add `HIDDEN_SPEC_SRC=; GATE_VISIBLE=`.

The HEAD check must see the authored spec without modifying `$GA_ROOT/head`. Replace the `hidden-on-head` line:

```sh
h=$GA_ROOT/head
[ -d "$h" ] || ga_die "no $h — run warm-cache.sh first"
if [ -n "${HIDDEN_SPEC_SRC:-}" ]; then
  # A throwaway copy of HEAD with the authored spec added; HEAD itself stays as exported.
  hv=$base/head-validate; rm -rf "$hv"; cp -R "$h" "$hv"; rm -rf "$hv/out"
  mkdir -p "$hv/$(dirname "$HIDDEN_SPEC")"; cp "$base/hidden/$HIDDEN_SPEC" "$hv/$HIDDEN_SPEC"
  mill_in 1800 "$hv" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
  rm -rf "$hv"
else
  mill_in 600 "$h" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
fi
```

Gate-visible check, before the final `printf`/`tee` (it needs the cut tree `$v` still present, so move `rm -rf "$v"` after it):

```sh
g=
if [ "${GATE_VISIBLE:-}" = 1 ]; then
  # Spec §4: on the cut tree, some test module other than TASK_MODULE, or the holdout, must fail.
  mods=$(python3 -c 'import json,sys;print(" ".join(m for m in sorted(json.load(open(sys.argv[1]))["modules"]) if m != sys.argv[2]))' \
    "$GA_ROOT/head-baseline.json" "$TASK_MODULE") || ga_die "read $GA_ROOT/head-baseline.json"
  rm -f "$v/$HIDDEN_SPEC"
  ho=$base/holdout-validate; rm -rf "$ho"; mkdir -p "$ho"
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | tar -x -C "$ho" || ga_die "holdout export"
  # shellcheck disable=SC2086
  { mill_in 1800 "$v" -k $mods && DSH_HOLDOUT_DIR=$(CDPATH= cd -- "$ho" && pwd -P) mill_in 600 "$v" holdout.test; } \
    >"$base/gate-visible.log" 2>&1 && g=no || g=yes
  rm -rf "$ho"
fi
rm -rf "$v"
printf 'cut_compiles=%s\nhidden_fails_on_cut=%s\nhidden_passes_on_head=%s\n' "$c" "$f" "$p" > "$base/validation.txt"
[ -z "$g" ] || printf 'gate_visible_on_cut=%s\n' "$g" >> "$base/validation.txt"
cat "$base/validation.txt"
[ "$c$f$p" = yesyesyes ] && [ "${g:-yes}" = yes ]
```

`mill_in` passes extra environment through because `DSH_HOLDOUT_DIR=… mill_in …` exports it for that function call's commands; confirm by reading `mill_in` (it runs `./mill` in a subshell inheriting the environment). If `-k` is not accepted by this Mill version in the real tree, the fake test still passes; Task 1's real-tree check happens in the operational step (Op 2), which records the log.

- [ ] **Step 4: Implement campaign.sh and lib.sh**

`lib.sh:10`:

```sh
GA_ALL_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth adsr sine by-offset sines-gen"
```

`GA_TASKS` default stays `$GA_ALL_TASKS`; to keep the A/B default unchanged, add right after it:

```sh
# The 4 gate-visible tasks (spec 2026-10-09) run only when named in GA_TASKS.
GA_AB_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"
GA_TASKS=${GA_TASKS:-$GA_AB_TASKS}
```

replacing the existing `GA_TASKS=${GA_TASKS:-$GA_ALL_TASKS}` line.

`campaign.sh` GA_REPS:

```sh
# Ruling 27: GA_REPS, a space-separated rep list (default "1 2 3"), each 1..4 (4: the gate-visible test phase's fresh ungated reps).
reps=${GA_REPS:-1 2 3}
[ -n "$(echo $reps)" ] || ga_die "GA_REPS is empty"
for r in $reps; do case $r in 1|2|3|4) ;; *) ga_die "GA_REPS: invalid rep '$r' (want 1..4)" ;; esac; done
```

`campaign.sh` preflight validation check:

```sh
  n=$(wc -l < "$v" 2>/dev/null | tr -d ' ')
  if [ "$(grep -c '=yes$' "$v" 2>/dev/null)" != "$n" ] || { [ "$n" != 3 ] && [ "$n" != 4 ]; }; then
```

If an existing shell test asserts the old GA_REPS error text, update its expected string to `(want 1..4)`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd eval/gate-ab/tests && sh shell-test.sh 2>&1 | tail -1 && python3 -m unittest -q test_report test_timeout test_score 2>&1 | tail -2`
Expected: `shell-test: N passed, 0 failed` (N > 130) and `OK`.

- [ ] **Step 6: Commit**

```bash
git add eval/gate-ab/prepare.sh eval/gate-ab/campaign.sh eval/gate-ab/lib.sh eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: authored hidden specs (HIDDEN_SPEC_SRC), gate-visible validation, reps 1..4

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 2: Tasks adsr and sine

**Files:**
- Create: `eval/gate-ab/tasks/adsr/{task.env,prompt.txt}`, `eval/gate-ab/tasks/adsr/stub/signals/src/com/github/mercurievv/skreeep2/signals/envelopes/ADSR.scala`, `eval/gate-ab/tasks/adsr/hidden/signals/test/src/com/github/mercurievv/skreeep2/ADSRSpec.scala`
- Create: `eval/gate-ab/tasks/sine/{task.env,prompt.txt}`, `eval/gate-ab/tasks/sine/stub/signals/src/com/github/mercurievv/skreeep2/signals/Sine.scala`, `eval/gate-ab/tasks/sine/hidden/signals/test/src/com/github/mercurievv/skreeep2/SineSpec.scala`

**Interfaces:**
- Consumes: Task 1's `HIDDEN_SPEC_SRC`, `GATE_VISIBLE`.
- Produces: tasks `adsr`, `sine` that the existing shell test "task <t> complete" loop checks once added to its task list (extend that loop's list with `adsr sine by-offset sines-gen` in Task 3 — or here for these two, then Task 3 adds the rest).

- [ ] **Step 1: task.env and prompt.txt**

`tasks/adsr/task.env`:

```sh
TASK_MODULE='signals.test'
HIDDEN_SPEC='signals/test/src/com/github/mercurievv/skreeep2/ADSRSpec.scala'
HIDDEN_SPEC_SRC='hidden/signals/test/src/com/github/mercurievv/skreeep2/ADSRSpec.scala'
GATE_VISIBLE=1
CUT_FILES='signals/src/com/github/mercurievv/skreeep2/signals/envelopes/ADSR.scala'
FEATURE='the ADSR envelope shape ADSR'
```

`tasks/adsr/prompt.txt` (no trailing newline, same wording as the other tasks):

```
The implementation of the ADSR envelope shape ADSR in signals/src/com/github/mercurievv/skreeep2/signals/envelopes/ADSR.scala has been removed: its members are ???. Implement it as its scaladoc and the project's docs describe. The existing tests must keep passing. Stop when you are done.
```

`tasks/sine/task.env`:

```sh
TASK_MODULE='signals.test'
HIDDEN_SPEC='signals/test/src/com/github/mercurievv/skreeep2/SineSpec.scala'
HIDDEN_SPEC_SRC='hidden/signals/test/src/com/github/mercurievv/skreeep2/SineSpec.scala'
GATE_VISIBLE=1
CUT_FILES='signals/src/com/github/mercurievv/skreeep2/signals/Sine.scala'
FEATURE='the partial oscillator maths Sine.sineCalc and Sine.advance'
```

`tasks/sine/prompt.txt`:

```
The implementation of the partial oscillator maths Sine.sineCalc and Sine.advance in signals/src/com/github/mercurievv/skreeep2/signals/Sine.scala has been removed: its members are ???. Implement it as its scaladoc and the project's docs describe. The existing tests must keep passing. Stop when you are done.
```

- [ ] **Step 2: Stubs**

Export the originals: `git -C /Users/viktorskalinins/IdeaProjects/skreeep2 show 6bf6c1b:<CUT_FILE> > tasks/<task>/stub/<CUT_FILE>`. Then:
- ADSR.scala: replace the whole body of `amplitudeAt` (from `val attackEnd` through `attackPart + decayPart + sustainPart + releasePart`, comment included) with a single `???` on the line after `=`; nothing else changes.
- Sine.scala: replace the body of `Sine.sineCalc` (`spire.math.sin(phase + chunkTime2Pi * frequency) * a.volume`) with `???`, and the body of `Sine.advance` (`Modulo[T].mod(phase + twoPi * frequency * chunkDuration, twoPi)`) with `???`. `slide`, `SinesGenerator` and all scaladoc stay unchanged.

Check with `diff <(git -C … show 6bf6c1b:<file>) tasks/<task>/stub/<file>`: only body lines differ.

- [ ] **Step 3: ADSRSpec (hidden)**

`signals.test` cannot see `backend.value`'s `OrderS[DenseVector[Double]]`; the spec defines a scalar `OrderS[Double]` itself. First read the trait: unzip `spire-opencl_3-0.1.6-sources.jar` from `~/Library/Caches/Coursier/v1/https/repo1.maven.org/maven2/io/github/mercurievv/spire-opencl_3/0.1.6/` (or the version skreeep2's `build.mill` pins — `git -C … show 6bf6c1b:build.mill | grep spire-opencl`) and read `io/github/mercurievv/spireopencl/algebra/OrderS.scala`, so the given below implements exactly its abstract members (TypeSystemBreeze's instance implements `greaterThan` and `<<`; `>>` is presumably derived from `greaterThan`). Adjust the given's member names to the trait; keep the semantics: `a >> b` is 1.0 when a > b else 0.0, `a << b` is 1.0 when a < b else 0.0.

```scala
package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.envelopes.ADSR
import io.github.mercurievv.spireopencl.algebra.OrderS
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what ADSR's scaladoc states, at scalar Double. Masks are strict comparisons, as on the device. */
object ADSRSpec extends SimpleIOSuite:

  private given OrderS[Double] with
    extension (a: Double)
      def greaterThan(b: Double): Double = if a > b then 1.0 else 0.0
      infix def <<(b: Double): Double = if a < b then 1.0 else 0.0

  // attack 0.1, decay 0.2, duration (whole step) 1.0, release 0.4, sustain 0.5; note starts at 2.0
  private val env = ADSR[Double](attack = 0.1, decay = 0.2, duration = 1.0, release = 0.4, sustainLevel = 0.5)
  private def at(t: Double): Double = env.amplitudeAt(t, 2.0)
  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-9

  // "ramp 0→1 over `attack`"
  pureTest("attack ramps linearly from 0 towards 1") {
    expect(near(at(2.05), 0.5)) and expect(near(at(2.025), 0.25))
  }

  // "1→`sustainLevel` over `decay`"
  pureTest("decay falls linearly from 1 to the sustain level") {
    expect(near(at(2.2), 0.75)) and expect(at(2.11) > 0.5) and expect(at(2.11) < 1.0)
  }

  // "flat over `sustain`" — sustain runs from attack+decay to `duration` ("the note's whole step")
  pureTest("sustain holds the sustain level until the step ends") {
    expect(near(at(2.5), 0.5)) and expect(near(at(2.99), 0.5))
  }

  // "then `sustainLevel`→0 over `release`"; release starts at start + duration
  pureTest("release falls linearly from the sustain level to 0") {
    expect(near(at(3.2), 0.25)) and expect(near(at(3.1), 0.375))
  }

  pureTest("silent before the note starts and after the release ends") {
    expect(near(at(1.0), 0.0)) and expect(near(at(1.999), 0.0)) and expect(near(at(3.5), 0.0)) and expect(near(at(10.0), 0.0))
  }
```

The scaladoc's "a note shorter than `attack + decay` never reaches sustain" is not tested: at HEAD the decay and release masks overlap for such a note, and the scaladoc does not state the resulting values.

Each `at(...)` point must lie strictly inside a segment (not on a boundary): boundary values depend on the strict masks and the scaladoc does not state them.

- [ ] **Step 4: SineSpec (hidden)**

```scala
package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.Sine
import io.github.mercurievv.spireopencl.algebra.Modulo
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what Sine.sineCalc's and Sine.advance's scaladoc states, at scalar Double. */
object SineSpec extends SimpleIOSuite:

  private given Modulo[Double] = Modulo.given_Modulo_Double
  private val twoPi = 2 * math.Pi
  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-9

  // "`sin(phi + 2*pi*f*(t - chunkStart))`" — chunkTime2Pi is 2*pi*(t - chunkStart)
  pureTest("a sample is sin(phase + chunkTime2Pi * frequency), scaled by the partial's volume") {
    val s = Sine(multiple = 2.0, volume = 0.3)
    val got = Sine.sineCalc(s, 440.0, 0.7, twoPi * 0.001)
    expect(near(got, math.sin(0.7 + twoPi * 0.001 * 440.0) * 0.3))
  }

  pureTest("at the chunk start the sample is sin(phase) times volume") {
    expect(near(Sine.sineCalc(Sine(1.0, 0.5), 1000.0, 1.2, 0.0), math.sin(1.2) * 0.5))
  }

  // "The phase one chunk later": phase + 2*pi*f*chunkDuration
  pureTest("advance adds one chunk's worth of phase") {
    expect(near(Sine.advance(10.0, twoPi, 0.01, 0.5), 0.5 + twoPi * 10.0 * 0.01))
  }

  // "folded back into a single turn"
  pureTest("advance wraps the phase into one turn") {
    val p = Sine.advance(440.0, twoPi, 0.1, 1.0)
    expect(p >= 0.0) and expect(p < twoPi) and expect(near(math.sin(p), math.sin(1.0 + twoPi * 440.0 * 0.1)))
  }

  // phase continuity: sample at the next chunk's start equals the sample at this chunk's end
  pureTest("the advanced phase continues the waveform across a chunk boundary") {
    val s = Sine(1.0, 1.0); val f = 523.25; val dur = 512.0 / 48000
    val endOfThis = Sine.sineCalc(s, f, 0.3, twoPi * dur)
    val startOfNext = Sine.sineCalc(s, f, Sine.advance(f, twoPi, dur, 0.3), 0.0)
    expect(math.abs(endOfThis - startOfNext) < 1e-9)
  }
```

`Modulo.given_Modulo_Double` is the name NoiseSpec uses at 6bf6c1b; keep it.

- [ ] **Step 5: Verify against HEAD and the cut (real tree, local only)**

In a scratch dir (not skreeep2): `git -C /Users/viktorskalinins/IdeaProjects/skreeep2 archive 6bf6c1b | tar -x -C <scratch>/head`; copy each hidden spec to its `HIDDEN_SPEC` path there; run `cd <scratch>/head && MILL_OUTPUT_DIR=out ./mill --no-daemon signals.test` → both specs pass. Then copy each stub over its file in a second copy with the spec present → that spec's tests fail (and compile). Fix the spec (never the stub) until both hold. Delete the scratch dirs. Record the pass/fail lines in the report.

- [ ] **Step 6: Shell test task loop and run tests**

In `tests/shell-test.sh`, extend the loop that checks "task $t complete" to include `adsr sine`, and make its completeness check accept `HIDDEN_SPEC_SRC`: when set, `[ -f "$d/$HIDDEN_SPEC_SRC" ]` must hold. Run both suites (Global Constraints); expect all pass.

- [ ] **Step 7: Commit**

```bash
git add eval/gate-ab/tasks/adsr eval/gate-ab/tasks/sine eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: gate-visible tasks adsr and sine with authored hidden specs

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 3: Tasks by-offset and sines-gen

**Files:**
- Create: `eval/gate-ab/tasks/by-offset/{task.env,prompt.txt}`, `…/stub/core/src/com/github/mercurievv/skreeep2/Globals.scala`, `…/hidden/<HIDDEN_SPEC>`
- Create: `eval/gate-ab/tasks/sines-gen/{task.env,prompt.txt}`, `…/stub/signals/src/com/github/mercurievv/skreeep2/signals/Sine.scala`, `…/hidden/signals/test/src/com/github/mercurievv/skreeep2/SinesGeneratorSpec.scala`

**Interfaces:**
- Consumes: Task 1 keys; Task 2's extended shell-test loop.

- [ ] **Step 1: Pick by-offset's test module**

`core` may have no test module (head-baseline modules list has none). Find which test module can compile a spec using `ForTime` and `AudioConfig` with plain `Double`/`Seq[Double]`: check `git -C … show 6bf6c1b:build.mill` for the lowest test module depending on `core` (likely `signals.test`). Use it as `TASK_MODULE`, and put the spec at `<module dir>/test/src/com/github/mercurievv/skreeep2/ForTimeSpec.scala`. `byOffset[T: Conversion[Seq[Double], _]]` needs a `Conversion[Seq[Double], T]`; with `T = Seq[Double]` supply `given Conversion[Seq[Double], Seq[Double]] = identity(_)` in the spec.

`tasks/by-offset/task.env` (fill the module/path chosen above, exact strings):

```sh
TASK_MODULE='<module>.test'
HIDDEN_SPEC='<module dir>/test/src/com/github/mercurievv/skreeep2/ForTimeSpec.scala'
HIDDEN_SPEC_SRC='hidden/<module dir>/test/src/com/github/mercurievv/skreeep2/ForTimeSpec.scala'
GATE_VISIBLE=1
CUT_FILES='core/src/com/github/mercurievv/skreeep2/Globals.scala'
FEATURE='the per-chunk sample clock ForTime.byOffset'
```

Prompt: same template as Task 2 with this FEATURE and CUT_FILES path.

Stub: only the body of `ForTime.byOffset` (the `val time`, `val timeSR`, and `ForTime[T, T](…)` lines) becomes `???`.

ForTimeSpec, with `AudioConfig.default.copy(SAMPLE_RATE = SampleRate(48000))` as the holdout's `OfflineRender.rate` does (imports `com.github.mercurievv.skreeep2.audio.{AudioConfig, SampleRate}`):

```scala
package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.audio.{AudioConfig, SampleRate}

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): ForTime.byOffset — one chunk's sample numbers from `offset`, and their times in seconds. */
object ForTimeSpec extends SimpleIOSuite:

  private given Conversion[Seq[Double], Seq[Double]] = identity(_)
  private val ac = AudioConfig.default.copy(SAMPLE_RATE = SampleRate(48000))

  pureTest("one chunk: clipSize consecutive sample numbers starting at the offset") {
    val ft = ForTime.byOffset[Seq[Double]](1000L, ac)
    expect(ft.sampleNumber.size == ac.clipSize) and
      expect(ft.sampleNumber.head == 1000.0) and
      expect(ft.sampleNumber.zip(ft.sampleNumber.tail).forall((a, b) => b - a == 1.0))
  }

  pureTest("times are sample numbers divided by the sample rate") {
    val ft = ForTime.byOffset[Seq[Double]](48000L, ac)
    expect(ft.time.head == 1.0) and expect(ft.time.zip(ft.sampleNumber).forall((t, n) => math.abs(t - n / 48000.0) < 1e-12))
  }

  pureTest("consecutive chunks tile the timeline without gap or overlap") {
    val a = ForTime.byOffset[Seq[Double]](0L, ac); val b = ForTime.byOffset[Seq[Double]](ac.clipSize.toLong, ac)
    expect(b.sampleNumber.head == a.sampleNumber.last + 1.0)
  }
```

The class has no scaladoc at 6bf6c1b; these tests state what the name, the signature and every caller (`GloabalSignals.create`, `OfflineRender`) rely on. Record that in the report. If `clipSize`'s type is not `Int`, adjust the `.size ==` comparison.

- [ ] **Step 2: sines-gen**

`tasks/sines-gen/task.env`:

```sh
TASK_MODULE='signals.test'
HIDDEN_SPEC='signals/test/src/com/github/mercurievv/skreeep2/SinesGeneratorSpec.scala'
HIDDEN_SPEC_SRC='hidden/signals/test/src/com/github/mercurievv/skreeep2/SinesGeneratorSpec.scala'
GATE_VISIBLE=1
CUT_FILES='signals/src/com/github/mercurievv/skreeep2/signals/Sine.scala'
FEATURE='the partial-set generators SinesGenerator.createSines, fromRatios and detuned'
```

Prompt: Task 2 template with this FEATURE and path. Stub: bodies of `SinesGenerator.createSines`, `fromRatios`, `detuned` become `???`; `square`, `DefaultSinesCount`, `Sine`, `slide` unchanged.

```scala
package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.{Sine, SinesGenerator}
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what SinesGenerator's scaladoc states, at Double. */
object SinesGeneratorSpec extends SimpleIOSuite:

  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-12

  // "`cnt` partials at 2f, 4f, 6f… … each with amplitude `vol / multiple`, paired with the id"; "**`cnt` is the number of partials.**"
  pureTest("createSines: cnt partials at even multiples, amplitude vol / multiple, positional ids") {
    val s = SinesGenerator.createSines[Double](1.2, 3, 10)
    expect(s.map(_._1) == List(10, 11, 12)) and
      expect(s.map(_._2.multiple) == List(2.0, 4.0, 6.0)) and
      expect(s.map(_._2.volume).zip(List(0.6, 0.3, 0.2)).forall(near))
  }

  pureTest("createSines with cnt = 2 gives two partials, not zero") {
    expect(SinesGenerator.createSines[Double](1.0, 2, 0).size == 2)
  }

  // "each partial's multiple of the fundamental and its own amplitude, in the caller's order"
  pureTest("fromRatios keeps the caller's ratios, amplitudes and order, ids from idBase") {
    val s = SinesGenerator.fromRatios(List((1.0, 0.5), (2.76, 0.25), (5.4, 0.1)), 7)
    expect(s == List((7, Sine(1.0, 0.5)), (8, Sine(2.76, 0.25)), (9, Sine(5.4, 0.1))))
  }

  // "clustered around the fundamental (`multiple = 1`), spread symmetrically by `spread` per step and each carrying `vol / cnt`"
  pureTest("detuned: symmetric cluster around 1 with step spread, each vol / cnt") {
    val s = SinesGenerator.detuned[Double](0.9, 3, 0.01, 0)
    expect(s.map(_._2.multiple).zip(List(0.99, 1.0, 1.01)).forall(near)) and expect(s.map(_._2.volume).forall(v => near(v, 0.3)))
  }

  pureTest("detuned with an even count has no partial exactly at 1 and stays symmetric") {
    val m = SinesGenerator.detuned[Double](1.0, 4, 0.02, 0).map(_._2.multiple)
    expect(!m.exists(near(_, 1.0))) and expect(near(m.sum / m.size, 1.0))
  }
```

`fromRatios[T, S[_]](ratios: S[(T, T)], idBase)(using Foldable[S])` needs `cats.instances.list` in scope if not automatic in cats 2 (it is automatic); if `VarId` is not `Int`, adapt the id literals to its type.

- [ ] **Step 3: Verify against HEAD and the cut**

As Task 2 Step 5, for both specs (by-offset's in its chosen module). Fix specs, never stubs.

- [ ] **Step 4: Shell test loop, run tests, commit**

Extend the "task $t complete" loop with `by-offset sines-gen`. Run both suites; expect all pass.

```bash
git add eval/gate-ab/tasks/by-offset eval/gate-ab/tasks/sines-gen eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: gate-visible tasks by-offset and sines-gen with authored hidden specs

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 4: README

**Files:**
- Modify: `eval/gate-ab/README.md` (append a section)

- [ ] **Step 1: Append**

```markdown
## Gate-visible tasks (screen, then same-day test)

Tasks `adsr`, `sine`, `by-offset`, `sines-gen` cut code that the holdout or downstream test modules exercise. Their
hidden specs were written for the study and live in `tasks/<task>/hidden/` (`HIDDEN_SPEC_SRC` in `task.env`);
`GATE_VISIBLE=1` makes `prepare.sh` add `gate_visible_on_cut` to `validation.txt`: on the cut tree, some test module
other than `TASK_MODULE`, or the holdout, must fail. They are not in the default task list. Spec:
`docs/superpowers/specs/2026-10-09-gate-visible-tasks-design.md` in scala-coding-guidelines.

```sh
R=~/gate-eval-hard   # own root: head/ copied from ~/gate-eval/head, settings snapshot and head-baseline.json copied
GA_ROOT=$R GA_ARMS=u GA_REPS="1 2" GA_TASKS="adsr sine by-offset sines-gen" sh eval/gate-ab/campaign.sh   # screen
GA_ROOT=$R/test GA_ARMS="g u" GA_REPS="1 2" GA_TASKS="<kept>" sh eval/gate-ab/campaign.sh               # test phase
```
```

(In the second command the test root links `base` and `head` from `$R`; fresh ungated runs are its `u` reps 1 and 2.)

- [ ] **Step 2: Commit**

```bash
git add eval/gate-ab/README.md
git commit -m "gate-ab: README — gate-visible tasks screen and test phase

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

## Operational steps (controller, after merge; not dispatched as tasks)

- **Op 1 — root:** `R=~/gate-eval-hard; mkdir -p $R/runs; cp -R ~/gate-eval/head $R/head; cp ~/gate-eval/gated-settings.json ~/gate-eval/gated-settings.json.sha256 ~/gate-eval/head-baseline.json $R/`.
- **Op 2 — prepare/validate:** `GA_ROOT=$R sh eval/gate-ab/prepare.sh <task>` for each of the 4. Drop any task whose `validation.txt` is not all yes (spec §4), recording why from its logs.
- **Op 3 — screen:** with `~/gate-eval/runs`, `~/gate-eval/invalid-runs`, `~/gate-eval-control/runs` chmod 000 for the duration, run the screen command (GA_TASKS = validated tasks). Audit contamination flags into `$R/runs/audit-cleared.txt`. Keep tasks with ungated solved ≤ 1 of 2.
- **Op 4 — pre-register:** write `$R/test/RULE.md` with spec §6's rule and the kept list before any test run. If no task kept, verdict "no gate-visible failure found; ungated sonnet handles these"; skip Op 5.
- **Op 5 — test phase:** `$R/test` with `base`, `head` symlinked to `$R`, settings and baseline copied; lock `$R/runs` and the older roots as in Op 3; run the test command. Audit flags. Apply the rule.
- **Op 6 — write-up:** raw file and roadmap item-1 update in scala-coding-guidelines, as for the control.
