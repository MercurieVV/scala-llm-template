# Downstream turn-end tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** At turn-end, also run the `turnEndTests` of every module that depends on a touched module, and block when one is red.

**Architecture:** The build answers who depends on whom: `Gate.moduleMapRows` (Mill recipe) emits a fourth map column
listing each module's dependents that have tests. The engine's `module-map.sh` accepts 3- or 4-column maps and gains a
`--dependents <id>` query. `turn-end.sh` collects the touched modules' dependents right after the owners' lookup (and
fails closed there), then runs them through the same `turnEndTests` path as the owners, refactored into one function.

**Tech Stack:** POSIX sh (engine, must run under `sh` and `dash`), awk, Mill 1.1.7 / Scala 3 (`Gate.mill`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-01-downstream-turn-end-tests-design.md`

## Global Constraints

- Engine code is POSIX sh: no arrays, no `local`, no `set -e`; it must pass under both `sh kit/harness/tests/run.sh` and `dash kit/harness/tests/run.sh`.
- Field 4 of a map row, when present, must match `^([A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)?$`.
- Default `module-map.sh <path>` output is unchanged: `<module id> TAB <capabilities>`, or `-`.
- `module-map.sh --dependents <id>`: one id per line, exit 0; nothing printed for a 3-column row, an empty field 4, or an id with no row; exit 3 when the map is missing/stale-unrebuildable or the row's field 4 is malformed.
- Downstream headings: block `turnEndTests: <D> (downstream of <M>) (failed)`; green `turnEndTests: <D> (downstream of <M>) green`; owner-failed note `downstream turnEndTests not run — <owner> failed first (<n> modules waiting)`.
- Downstream remedy line: ``your change to `<M>` broke `<D>`'s tests — fix `<M>` (or update `<D>` if the change is intended); run `./mill <D>.test` to reproduce``.
- Cap/budget: same `DSH_TESTS_CAP` (default 300) and `DSH_STOP_BUDGET` (default 540) as owners; ≤ 10 s left → not started.
- A test-only change (every touched file of `M` under `<M dir>/test/`) does not pull in `M`'s dependents.
- `Gate.moduleMapRows` gains `downstreamExcluded: Seq[Module] = Nil`; every row has four columns (field 4 possibly empty).
- Commits end with `Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU`; never a `Co-Authored-By` trailer.

## Review Focus

1. A module id that is a prefix of another (`core` vs `core.api`) in field 4 or in the owners list — dedup and "already an owner" must compare whole ids, never substrings. (Task 2, case `turn-end-downstream-id-prefix`.)
2. A dependent whose map row lacks the `tests` capability (a stale or hand-edited map lists it) — it is skipped, never run and never a crash; one with no `turnEndTests` contract line is skipped by `te_run`'s `dsh_contract_for_module … || return 0`, like an owner. (Task 2, case `turn-end-downstream-no-contract`.)
3. A 4-column map read by every other reader (`feedback.sh` draft roots, `dsh_holdout_checks`) must behave exactly as with 3 columns. (Task 1, rows in `feedback-test.sh` and `lib-test.sh`.)
4. A map whose last line has no trailing newline and four fields — `--dependents` must still answer for that row. (Task 1, row in `module-map-test.sh`.)
5. A dependent that is also a *kernel* module for vericoding — downstream runs must not change which modules the vericoding stage receives (it keys on `blockmods`; a downstream block adds the dependent to `blockmods`, which is correct: no Stainless run after a red test). Pinned by the existing vericoding cases staying green in the full suite run of Task 2.

---

### Task 1: `module-map.sh` reads four-column maps and answers `--dependents`

**Files:**
- Modify: `kit/harness/module-map.sh` (`map_clean`, the lookup `read`, new `--dependents` mode)
- Modify: `kit/harness/hooks/feedback.sh:52` (the `read -r mdir _mod _caps` loop)
- Modify: `kit/harness/lib.sh` (`dsh_holdout_checks`'s `read -r _hc_dir _hc_mod _hc_caps` loop)
- Modify: `kit/harness/README.md` (the `moduleMap` row's format description)
- Test: `kit/harness/tests/module-map-test.sh`, `kit/harness/tests/feedback-test.sh`, `kit/harness/tests/lib-test.sh`

**Interfaces:**
- Produces: `sh .dsh/engine/module-map.sh --dependents <module id>` → stdout one dependent id per line; exit 0, or exit 3 with one line on stderr. Task 2 consumes it.

- [ ] **Step 1: Write the failing tests in `module-map-test.sh`**

Insert before the final `rm -rf "$scratch" "$linkdir"` block:

```sh
# --- four-column maps (spec 2026-10-01 §2): field 4 lists a module's dependents with tests --------
seed_map4() {
  {
    printf 'engine\tengine\tfmt,scalafix\tengine.shape,scope\n'
    printf 'engine/shape\tengine.shape\tfmt,scalafix,tests\tscope\n'
    printf 'scope\tscope\tfmt,tests\t\n'
    printf 'bench\tbench\tfmt,scalafix,tests'
  } > "$map"
}
seed_map4
touch -t 202001010000 "$scratch/build.mill"
touch -t 203001010000 "$map"

check "a four-column row answers the lookup with id and capabilities only" "$scratch/engine/shape/src/Host.scala" "engine.shape${tab}fmt,scalafix,tests"
check "an empty fourth column keeps the capabilities intact" "$scratch/scope/src/S.scala" "scope${tab}fmt,tests"

capture_dep() { # capture_dep <id> [env…]
  cid=$1; shift
  errfile=$(mktemp)
  out=$(env "$@" GATE_ROOT="$scratch" STUB_LOG="$log" "$shell_bin" "$dsh" --dependents "$cid" 2>"$errfile")
  code=$?
  err=$(cat "$errfile"); rm -f "$errfile"
}
capture_dep engine
is "--dependents lists field 4, one per line" "$(printf 'engine.shape\nscope')" "$out"
is "--dependents exits 0" "0" "$code"
capture_dep scope
is "--dependents on an empty field 4 prints nothing" "" "$out"
is "--dependents on an empty field 4 exits 0" "0" "$code"
capture_dep bench
is "--dependents on a three-column last line without newline prints nothing" "" "$out"
capture_dep nosuch
is "--dependents on an unknown id prints nothing" "" "$out"
is "--dependents on an unknown id exits 0" "0" "$code"
capture_dep engine.sh
is "--dependents compares whole ids, never a prefix" "" "$out"

printf 'engine\tengine\tfmt\tscope;rm\n' > "$map"; touch -t 203001010000 "$map"
capture_dep engine
is "--dependents on a malformed field 4 exits 3" "3" "$code"
is "--dependents on a malformed field 4 prints nothing" "" "$out"
case "$err" in *"module-map:"*) ok "--dependents on a malformed field 4 says why" ;; *) bad "--dependents on a malformed field 4 gave no reason: [$err]" ;; esac

rm -f "$map"; touch -t 203001010000 "$scratch/build.mill"
capture_dep engine STUB_EXIT=1
is "--dependents with no map and a failing Mill exits 3" "3" "$code"

# A refreshed map with four columns is installed; one with a bad field 4 is refused.
cat > "$scratch/mill4" <<'STUB'
#!/bin/sh
printf 'mill %s\n' "$*" >> "$STUB_LOG"
if [ "${STUB_BAD4:-0}" = 1 ]; then printf 'engine\tengine\tfmt\tscope;x\n'; exit 0; fi
printf 'engine\tengine\tfmt,scalafix\tscope\n'
printf 'scope\tscope\tfmt,tests\t\n'
STUB
cp "$scratch/mill" "$scratch/mill3"; cp "$scratch/mill4" "$scratch/mill"; chmod +x "$scratch/mill"
check "a refreshed four-column map is installed" "$scratch/scope/src/S.scala" "scope${tab}fmt,tests"
is "the installed map keeps field 4" "engine${tab}engine${tab}fmt,scalafix${tab}scope" "$(sed -n '1p' "$map")"
rm -f "$map"; touch -t 203001010000 "$scratch/build.mill"
cannot_decide "a refreshed map with a malformed field 4" "$scratch/scope/src/S.scala" STUB_BAD4=1
cp "$scratch/mill3" "$scratch/mill"; chmod +x "$scratch/mill"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh kit/harness/tests/module-map-test.sh 2>&1 | grep -E '^FAIL|passed'`
Expected: FAIL lines for "a four-column row answers…" (caps column contains the dependents), every `--dependents` row, and "a refreshed four-column map is installed" (`map_clean` refuses 4 fields).

- [ ] **Step 3: Implement in `module-map.sh`**

Replace `map_clean` with:

```sh
# Is $1 a map this script can use? Three or four fields per row — `<module dir>`, `<module id>`,
# `<capabilities>` and, from spec 2026-10-01, `<dependents>` — and nothing else. ... (keep the existing
# paragraph, then add:) The fourth field, when present, is a comma-separated list of module ids (possibly
# empty): the modules whose `test` suite depends on this one, which turn-end also runs.
map_clean() {
  awk -v dir_re='^[A-Za-z0-9._/-]+$' -v mod_re='^[A-Za-z0-9._-]+$' \
    -v caps_re='^(fmt|tests|fmt,tests|scalafix|scalafix,tests|fmt,scalafix|fmt,scalafix,tests)?$' \
    -v deps_re='^([A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)?$' '
    {
      n = split($0, fields, "\t")
      if (n != 3 && n != 4) bad = 1
      else if (fields[1] !~ dir_re || fields[2] !~ mod_re) bad = 1
      else if (fields[3] !~ caps_re) bad = 1
      else if (n == 4 && fields[4] !~ deps_re) bad = 1
    }
    END { exit !(NR > 0 && !bad) }
  ' "$1"
}
```

Before the `[ -s "$map" ] || …` refresh block's argument handling, capture the mode (put this right after `set -u` and the `. lib.sh` line):

```sh
dep_query=''
if [ "${1:-}" = "--dependents" ]; then dep_query=${2:-}; set -- "${2:-}"; fi
```

Immediately after the `[ -s "$map" ] || { … exit 3; }` block, add:

```sh
# --dependents <id> (spec 2026-10-01 §2): the row's fourth field, one id per line. A three-column row, an
# empty field or an id with no row print nothing (exit 0); a malformed field 4 cannot decide (exit 3) —
# turn-end must block on that, never read it as "no dependents".
if [ -n "$dep_query" ]; then
  awk -F'\t' -v m="$dep_query" -v deps_re='^([A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)?$' '
    $2 == m {
      if (NF >= 4) {
        if ($4 !~ deps_re || NF > 4) { bad = 1; exit }
        n = split($4, d, ",")
        for (i = 1; i <= n; i++) print d[i]
      }
      exit
    }
    END { exit bad ? 3 : 0 }
  ' "$map"
  dq_code=$?
  if [ "$dq_code" != 0 ]; then
    printf '%s\n' "module-map: cannot list the dependents of '$dep_query' — its row in $map has a malformed fourth column" >&2
    exit 3
  fi
  exit 0
fi
```

(The awk prints only after validating, because `bad` is checked before `split`; on a malformed row nothing is printed. Capture stdout in a variable first if dash buffering makes partial output possible: `dq_out=$(awk …); dq_code=$?; [ "$dq_code" = 0 ] && [ -n "$dq_out" ] && printf '%s\n' "$dq_out"`.)

Change the lookup loop's read to keep field 4 out of `caps`:

```sh
while IFS="$(printf '\t')" read -r dir module caps _deps; do
```

Also: the `cannot_decide` stderr wording for the `--dependents` mode should name the id, not a path — in the two `printf … "module-map: cannot decide which module owns '${1:-}' …"` lines, `${1:-}` is already the id after the `set --` above, which reads acceptably; leave the wording.

- [ ] **Step 4: Run it to verify it passes**

Run: `sh kit/harness/tests/module-map-test.sh 2>&1 | tail -3 && dash kit/harness/tests/module-map-test.sh 2>&1 | tail -1`
Expected: `… passed, 0 failed` under both shells.

- [ ] **Step 5: Write failing reader tests (Review Focus 3)**

In `kit/harness/tests/feedback-test.sh`, right after the existing row at line 63 (`modules.tsv restricts draft roots (app not listed)`), add a copy of that row whose map is written with a fourth column:

```sh
printf 'core\tcore\ttests\tapp\n' > "$scratch/.dsh/.state/modules.tsv"
```

followed by the same invocation and the same expected value as the line-63 row, named `"wrapper: a four-column modules.tsv restricts draft roots the same way"`. Then restore the three-column map the following rows expect (`printf 'app\tapp\ttests\n' > …`, as line 64 does).

In `kit/harness/tests/lib-test.sh`, after the existing `hc` rows that use `$hcroot` (around line 1140), add:

```sh
printf 'engine\tengine\tfmt,scalafix,tests\twiring\nwiring\twiring\tfmt,tests\t\nholdout\tholdout\t\t\n' > "$hcroot/.dsh/.state/modules.tsv"
is "holdout checks: a four-column map gives the same verdict as three columns" \
  "$hc3_out" "$(hc "$hcroot")"
```

where `hc3_out` is captured just before this row with the three-column map that block already writes (`hc3_out=$(hc "$hcroot")`). Restore the three-column map afterwards.

- [ ] **Step 6: Run them to verify they fail**

Run: `sh kit/harness/tests/feedback-test.sh 2>&1 | grep -E 'four-column|passed'; sh kit/harness/tests/lib-test.sh 2>&1 | grep -E 'four-column|passed'`
Expected: at least the `lib-test` row FAILs (`_hc_caps` holds `fmt,scalafix,tests<TAB>wiring`); if a row passes before the fix, keep it (it pins behaviour) and note it in the report.

- [ ] **Step 7: Fix the readers**

`kit/harness/hooks/feedback.sh`: `while IFS="$(printf '\t')" read -r mdir _mod _caps _deps; do`
`kit/harness/lib.sh` (`dsh_holdout_checks`): `while IFS="$_hc_tab" read -r _hc_dir _hc_mod _hc_caps _hc_deps; do`
Then grep for any other `read -r` over `modules.tsv`: `grep -n 'read -r' kit/harness/*.sh kit/harness/hooks/*.sh | grep -v '_line\b'` and give every three-variable read over the map a fourth throwaway variable.

- [ ] **Step 8: Run all three direct suites under both shells**

Run: `for s in sh dash; do for t in module-map-test feedback-test lib-test; do $s kit/harness/tests/$t.sh 2>&1 | tail -1; done; done`
Expected: every line `… passed, 0 failed` (lib-test may print `… skipped` too; 0 failed is the bar).

- [ ] **Step 9: Document the format**

In `kit/harness/README.md`, the `moduleMap` row (line ~177) and the sentence describing `modules.tsv`: state the rows are `<dir> TAB <id> TAB <capabilities> [TAB <dependents>]`, that field 4 is written by `Gate.moduleMapRows` from Mill's module graph, and that `module-map.sh --dependents <id>` reads it.

- [ ] **Step 10: Commit**

```bash
git add kit/harness/module-map.sh kit/harness/hooks/feedback.sh kit/harness/lib.sh kit/harness/README.md \
  kit/harness/tests/module-map-test.sh kit/harness/tests/feedback-test.sh kit/harness/tests/lib-test.sh
git commit -m "kit(harness): the module map carries dependents; module-map.sh --dependents

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

---

### Task 2: turn-end runs the dependents' `turnEndTests`

**Files:**
- Modify: `kit/harness/tests/run.sh:88` (case filter)
- Modify: `kit/harness/hooks/turn-end.sh` (collect dependents after the owners' map loop ~line 672; refactor the `turnEndTests` loop ~lines 1022-1070 into `te_run`; downstream stage after it)
- Modify: `kit/harness/README.md` (the turn-end headline table ~lines 536-540 and the `turnEndTests` contract row ~line 143)
- Create: 12 cases under `kit/harness/tests/cases/` (listed in Step 2)

**Interfaces:**
- Consumes: `sh "$here/module-map.sh" --dependents <id>` (Task 1): ids one per line, exit 0 / exit 3 + stderr.
- Produces: headings exactly as in Global Constraints.

- [ ] **Step 1: Add a case filter to the runner**

`kit/harness/tests/run.sh` line 88: `for case_dir in "$cases_dir"/${RUN_CASES:-*}/; do` and one header-comment line: `RUN_CASES=<glob> runs only the matching case directories (a TDD convenience; the full run is the gate).`

- [ ] **Step 2: Write the failing cases**

Every case below has: `subcommand` = `turn-end`; `payload.json` = `{"session_id":"s1","hook_event_name":"Stop"}`; an empty `git_init`; `root/.dsh/contract` = `turnEndTests = sh .dsh/te-stub.sh <module>`; one `root/<dir>/src/<X>.scala` per module containing `object X` (any one line); and `root/.dsh/.state/modules.tsv` written with real tabs. `post_git` scripts start with `#!/bin/sh`. The shared stub (`root/.dsh/te-stub.sh`) unless a case gives its own:

```sh
#!/bin/sh
# Records each module it ran, then fails for the module(s) named in .dsh/te-red (one id per line).
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "$1" >> "$d/te-calls.log"
if [ -f "$d/te-red" ] && grep -qx "$1" "$d/te-red"; then
cat <<'T'
Running Test Class com.x.PhraseProps
com.x.PhraseProps
+ passes 1ms
- strikes are strictly increasing 4ms

*************FAILURES**************
com.x.PhraseProps
- strikes are strictly increasing 4ms
 [0] Property test failed on try 3 with seed Seed.fromBase64("AAA=") and input List(Strike(0.0), Strike(0.0)) (modules/scalacheck/src/weaver/scalacheck/Checkers.scala:195)

 [1] assertion failed (PhraseProps.scala:12)

T
exit 1
fi
printf 'com.x.PhraseProps\n+ passes 1ms\nTotal 1, Failed 0, Passed 1, Ignored 0, Cancelled 0\n'
exit 0
```

`post_gate` scripts receive `GATE_OUT_FILE`; "absent" assertions use `! grep -qF '<text>' "$GATE_OUT_FILE"`.

1. `turn-end-downstream-block` — map: `core	core	tests	app` / `app	app	tests	`; `root/.dsh/te-red`: `app`; post_git: `printf '\n// touched\n' >> core/src/K.scala`. `expect.code` 2. `expect.grep`:
   ```
   turnEndTests: app (downstream of core) (failed)
   your change to `core` broke `app`'s tests
   ./mill app.test
   ```
2. `turn-end-downstream-green` — as 1 without `te-red`. `expect.code` 0. `expect.grep`: `turnEndTests: core green` / `turnEndTests: app (downstream of core) green`.
3. `turn-end-downstream-test-only` — as 1, plus `root/core/test/src/T.scala`; post_git touches only `core/test/src/T.scala`. `expect.code` 0. `post_gate`: `! grep -q '^app$' .dsh/te-calls.log && ! grep -qF 'downstream of' "$GATE_OUT_FILE"`.
4. `turn-end-downstream-owner-failed` — as 1 but `te-red`: `core`. `expect.code` 2. `expect.grep`: `turnEndTests: core (failed)` / `downstream turnEndTests not run — core failed first (1 modules waiting)`. `post_gate`: `! grep -q '^app$' .dsh/te-calls.log`.
5. `turn-end-downstream-shared-once` — map: `core	core	tests	app` / `lib	lib	tests	app` / `app	app	tests	`; post_git touches `core/src/K.scala` and `lib/src/L.scala`. `expect.code` 0. `expect.grep`: `turnEndTests: app (downstream of core) green`. `post_gate`: `[ "$(grep -c '^app$' .dsh/te-calls.log)" = 1 ]`.
6. `turn-end-downstream-owner-not-twice` — map as 1; post_git touches `core/src/K.scala` and `app/src/A.scala`. `expect.code` 0. `expect.grep`: `turnEndTests: app green`. `post_gate`: `[ "$(grep -c '^app$' .dsh/te-calls.log)" = 1 ] && ! grep -qF '(downstream of core)' "$GATE_OUT_FILE"`.
7. `turn-end-downstream-three-column` — map: `core	core	tests` / `app	app	tests`; `te-red`: `app`; post_git touches core. `expect.code` 0. `post_gate`: `! grep -q '^app$' .dsh/te-calls.log`.
8. `turn-end-downstream-malformed` — map: `core	core	tests	app;x` / `app	app	tests	`; post_git touches core. `expect.code` 2. `expect.grep`: `malformed fourth column`.
9. `turn-end-downstream-budget` — map as 1; `env`: `DSH_STOP_BUDGET=16`; own stub = the shared stub with `case "$1" in core) sleep 7 ;; esac` inserted after the `printf … te-calls.log` line; post_git touches core. `expect.code` 0. `expect.grep`: `turnEndTests: app (downstream of core) not started — the Stop hook's budget`. `post_gate`: `! grep -q '^app$' .dsh/te-calls.log`. (Same margin reasoning as `turnendtests-budget-skips-next`.)
10. `turn-end-downstream-draft` — map as 1; `te-red`: `app`; plus `root/app/test-draft/src/x/PhraseProps.scala` copied from `turn-end-tests-draft-only/root/app/test-draft/src/x/PhraseProps.scala`; post_git touches core. `expect.code` 0. `expect.grep`: `turnEndTests: app (downstream of core) (1 draft failure(s) — noted)`.
11. `turn-end-downstream-id-prefix` (Review Focus 1) — map: `core	core	tests	core.api` / `core/api	core.api	tests	` ; post_git touches `core/src/K.scala` only. `expect.code` 0. `expect.grep`: `turnEndTests: core.api (downstream of core) green`. `post_gate`: `[ "$(grep -c '^core.api$' .dsh/te-calls.log)" = 1 ]`.
12. `turn-end-downstream-no-contract` (Review Focus 2) — map as 1; contract line is `turnEndTests = sh .dsh/te-stub.sh <module>` but `te-stub.sh` exits 0 for everything and the map's `app` row has an EMPTY capability field (`app	app		`), so the dependent has no `tests` capability. `expect.code` 0. `post_gate`: `! grep -q '^app$' .dsh/te-calls.log`.

- [ ] **Step 3: Run them to verify they fail**

Run: `RUN_CASES='turn-end-downstream-*' sh kit/harness/tests/run.sh 2>&1 | tail -15`
Expected: cases 1, 2, 4, 5, 8, 9, 10, 11 FAIL (no downstream stage yet); 3, 6, 7, 12 may pass already (they assert absence) — that is fine.

- [ ] **Step 4: Collect dependents after the owners' map loop**

In `turn-end.sh`, directly after `done < "$tmpd/scala"` that ends the `--- which modules own them` loop (~line 674), add:

```sh
# --- which modules depend on them (spec 2026-10-01 §3) ---------------------------------------------
# For each touched module with at least one touched file outside its own `test/` (a test-only change
# cannot break a dependent), the build's list of dependents (`module-map.sh --dependents`, the map's
# fourth column). Union, minus the owners, sorted by id; each remembers the first touched module (by id)
# that pulled it in. Read here, beside the owners' lookup, so a map that cannot answer fails closed
# before any check runs — the same rule the owners' lookup follows.
: > "$tmpd/ds"   # <dependent> TAB <touched module that pulled it in>
sort "$tmpd/mods" | while IFS="$tab" read -r ds_m _ds_caps; do
  [ -n "$ds_m" ] || continue
  ds_dir=$(awk -F"$tab" -v m="$ds_m" '$2 == m { print $1; exit }' "$st/modules.tsv" 2>/dev/null)
  ds_main=0
  while IFS="$tab" read -r _m _f; do
    [ "$_m" = "$ds_m" ] || continue
    _rel=$_f
    case "$ds_dir" in ''|.) ;; *) _rel=${_f#"$ds_dir"/} ;; esac
    case "$_rel" in test/*) ;; *) ds_main=1; break ;; esac
  done < "$tmpd/modfiles"
  [ "$ds_main" = 1 ] || continue
  if ! sh "$here/module-map.sh" --dependents "$ds_m" > "$tmpd/ds-one" 2>"$tmpd/ds-err"; then
    printf '%s\n' "$ds_m" > "$tmpd/ds-failed"; break
  fi
  while IFS= read -r ds_d; do
    [ -n "$ds_d" ] || continue
    awk -F"$tab" -v d="$ds_d" '$1 == d { f = 1 } END { exit !f }' "$tmpd/mods" && continue
    awk -F"$tab" -v d="$ds_d" '$1 == d { f = 1 } END { exit !f }' "$tmpd/ds" && continue
    printf '%s\t%s\n' "$ds_d" "$ds_m" >> "$tmpd/ds"
  done < "$tmpd/ds-one"
done
if [ -s "$tmpd/ds-failed" ]; then
  block "this turn cannot be checked — the module map could not list the modules that depend on $(cat "$tmpd/ds-failed"), so the tests this change can break cannot be chosen.
$(cat "$tmpd/ds-err" 2>/dev/null)
The build or its map is broken, and this gate fails closed: run ./mill --ticker false moduleMap by hand, fix what it reports, then end the turn again."
fi
sort -t "$tab" -k1,1 "$tmpd/ds" > "$tmpd/ds.sorted" && mv "$tmpd/ds.sorted" "$tmpd/ds"
```

(The pipeline's `while` runs in a subshell, so it communicates only through files — `$tmpd/ds`, `$tmpd/ds-failed` — never variables.)

- [ ] **Step 5: Refactor the `turnEndTests` loop body into `te_run`**

Replace the loop `while IFS="$tab" read -r te_mod te_caps; do … done < "$tmpd/mods"` (keep the comment block and the `te_tests_cap`/`te_stop_budget`/`te_budget_out`/`te_stopped`/`te_left`/`te_greens`/`fb_noted` initialisation above it) with:

```sh
te_failed=''
# te_run <module> <origin>: one module's turnEndTests, under the shared cap and budget. <origin> is
# empty for a touched module and the touched module that pulled it in for a dependent (spec 2026-10-01
# §3): it is named in every heading as ` (downstream of <origin>)`, and a red dependent gets a remedy
# line pointing back at the change. Sets te_stopped=1 and te_failed on a block.
te_run() {
  te_mod=$1; te_origin=$2
  te_from=''; [ -n "$te_origin" ] && te_from=" (downstream of $te_origin)"
  te_cmd=$(dsh_contract_for_module turnEndTests "$te_mod" "$root") || return 0
  if [ "$te_stopped" = 1 ]; then te_left=$((te_left + 1)); return 0; fi
  if [ "$te_budget_out" = 1 ]; then
    te_left=$((te_left + 1))
    vk_add "turnEndTests: $te_mod$te_from not started — the Stop hook's budget" "no time was left of the $te_stop_budget s Stop-hook budget when $te_mod's turn came, so its turnEndTests were not started. Not verified this turn; run it by hand, or end the turn again once other modules are green."
    return 0
  fi
  te_now=$(date +%s 2>/dev/null) || te_now=''
  case "$te_start$te_now" in
    *[!0-9]*|'') te_budget_left=$te_stop_budget ;;
    *) te_budget_left=$((te_stop_budget - (te_now - te_start))) ;;
  esac
  if [ "$te_budget_left" -le 10 ]; then
    te_budget_out=1
    te_left=$((te_left + 1))
    vk_add "turnEndTests: $te_mod$te_from not started — the Stop hook's budget" "$te_budget_left s of the $te_stop_budget s Stop-hook budget were left when $te_mod's turn came, so its turnEndTests were not started. Not verified this turn; run it by hand, or end the turn again once other modules are green."
    return 0
  fi
  te_cap=$te_tests_cap
  [ "$te_budget_left" -lt "$te_cap" ] && te_cap=$te_budget_left
  rm -f "$tmpd/te-out" "$tmpd/te-err" "$tmpd/te-rc"
  if dsh_bounded_probe "$te_cap" "$tmpd/te-out" "$tmpd/te-err" \
       sh -c '"$@" 2>&1; printf "%s" "$?" > "$0"' "$tmpd/te-rc" \
       sh "$here/hooks/feedback.sh" --selector "$te_mod.test" -- sh -c "$te_cmd"; then
    te_out=$(cat "$tmpd/te-out" 2>/dev/null)
    te_rc=$(cat "$tmpd/te-rc" 2>/dev/null)
    case "$te_rc" in ''|*[!0-9]*) te_rc=1 ;; esac
  else
    vk_add "turnEndTests: $te_mod$te_from did not finish within $te_cap s — not verified" "the run was killed at the ${te_cap} s cap (DSH_TESTS_CAP, default 300, bounded by what was left of the Stop hook's own budget) and never reached a verdict. Not counted as a failure; run it by hand, or end the turn again."
    return 0
  fi
  if [ "$te_rc" = 0 ]; then te_greens="$te_greens
turnEndTests: $te_mod$te_from green"; return 0; fi
  te_remedy=''
  [ -n "$te_origin" ] && te_remedy="
your change to \`$te_origin\` broke \`$te_mod\`'s tests — fix \`$te_origin\` (or update \`$te_mod\` if the change is intended); run \`./mill $te_mod.test\` to reproduce"
  te_nondraft=$(printf '%s\n' "$te_out" | grep -Ec '^(PROPERTY|TEST|INFRA|UNREADABLE):')
  te_drafts=$(printf '%s\n' "$te_out" | grep -Ec '^DRAFT ')
  if [ "$te_nondraft" -gt 0 ]; then
    blocked=$((blocked + 1)); blockmods="$blockmods $te_mod"
    section blocking "turnEndTests: $te_mod$te_from (failed)" "$te_out$te_remedy"; te_stopped=1; te_failed=$te_mod
  elif [ "$te_drafts" -gt 0 ]; then
    fb_noted=$((fb_noted + 1)); section note "turnEndTests: $te_mod$te_from ($te_drafts draft failure(s) — noted)" "$te_out"
  else
    blocked=$((blocked + 1)); blockmods="$blockmods $te_mod"
    section blocking "turnEndTests: $te_mod$te_from failed (exit $te_rc) with no failure records — see the log" "$te_out$te_remedy"; te_stopped=1; te_failed=$te_mod
  fi
  return 0
}

while IFS="$tab" read -r te_mod te_caps; do
  [ -n "$te_mod" ] || continue
  case ",$te_caps," in *,tests,*) ;; *) continue ;; esac
  te_run "$te_mod" ''
done < "$tmpd/mods"
[ "$te_left" -gt 0 ] && report="$report
$te_left modules not run — fix this one first"

# --- downstream turnEndTests (spec 2026-10-01 §3) ---------------------------------------------------
# The touched modules' dependents (collected beside the owners' lookup above), through the same te_run:
# same cap, same budget, same verdict rule, a block counts toward the attempt cap. Only when every owner
# was green — a red owner is the thing to fix first, and its dependents would mostly repeat it.
if [ -s "$tmpd/ds" ]; then
  ds_n=$(awk 'END { print NR }' "$tmpd/ds")
  if [ "$te_stopped" = 1 ]; then
    report="$report
downstream turnEndTests not run — $te_failed failed first ($ds_n modules waiting)"
  else
    te_left=0
    while IFS="$tab" read -r ds_d ds_m; do
      [ -n "$ds_d" ] || continue
      ds_caps=$(awk -F"$tab" -v m="$ds_d" '$2 == m { print $3; exit }' "$st/modules.tsv" 2>/dev/null)
      case ",$ds_caps," in *,tests,*) ;; *) continue ;; esac
      te_run "$ds_d" "$ds_m"
    done < "$tmpd/ds"
    [ "$te_left" -gt 0 ] && report="$report
$te_left downstream modules not run — fix this one first"
  fi
fi
```

Check the exact original text of the two `vk_add` bodies and the `section` calls against the file before replacing (the only intended changes are `continue`→`return 0`, `$te_mod`→`$te_mod$te_from` in headings, the remedy, and `te_failed`). Note that `te_run` assigns globals (`te_mod`, `te_cmd`, …) exactly as the loop did — code after the loop that reads them sees the last module's values, as before.

The owner-failed note: spec §3.2 calls it a note; `report` is the channel the existing "modules not run" line uses, so it reaches the agent in the same place. Record this as a ruling in the ledger if a reviewer asks for `vk_add` instead.

- [ ] **Step 6: Run the new cases to verify they pass**

Run: `RUN_CASES='turn-end-downstream-*' sh kit/harness/tests/run.sh 2>&1 | tail -15`
Expected: `12 passed, 0 failed` (wording per runner's summary line).

- [ ] **Step 7: Run the full suite under both shells**

Run: `sh kit/harness/tests/run.sh > /tmp/te-sh.log 2>&1; tail -3 /tmp/te-sh.log; dash kit/harness/tests/run.sh > /tmp/te-dash.log 2>&1; tail -3 /tmp/te-dash.log`
Expected: 0 failed in both. In particular every existing `turn-end-tests-*`, `turnendtests-*` and `vericoding-*` case stays green (Review Focus 5).

- [ ] **Step 8: Document**

`kit/harness/README.md`: in the headline table next to the `turnEndTests: <module> …` rows, add rows for `turnEndTests: <D> (downstream of <M>) (failed)` (finding, blocks), `… green`, the not-started / did-not-finish variants with `(downstream of <M>)`, `downstream turnEndTests not run — <owner> failed first (<n> modules waiting)` (degradation) and `<n> downstream modules not run — fix this one first`. In the contract table row for `turnEndTests` (~line 143) add: "and, from spec 2026-10-01, for each touched module's dependents (the map's fourth column)". Under the `DSH_TESTS_CAP` section add one sentence: dependents share the same cap and budget, after the owners.

- [ ] **Step 9: Commit**

```bash
git add kit/harness/hooks/turn-end.sh kit/harness/tests/run.sh kit/harness/README.md kit/harness/tests/cases/turn-end-downstream-*
git commit -m "kit(harness): turn-end runs the touched modules' dependents' turnEndTests

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

---

### Task 3: `check-harness` says when the map has no dependents column

**Files:**
- Modify: `kit/harness/lib.sh` (new `dsh_dependents_column_check`, next to `dsh_holdout_checks`)
- Modify: `kit/harness/check-harness.sh` (map its rows, after the holdout block ~line 613)
- Test: `kit/harness/tests/lib-test.sh`

**Interfaces:**
- Produces: `dsh_dependents_column_check [root]` → rows `ok|note` TAB `<message>`; always exit 0.

Ruling carried from planning: the spec says `WARN`; `check-harness.sh` has no WARN verb, only `ok`/`FAIL`/`note`, and `note` is defined there as "a state this checkout is allowed to be in … not counted as coverage" — which is what the spec means. Use `note`.

- [ ] **Step 1: Write the failing tests** (in `lib-test.sh`, after the `hc` rows)

```sh
dcc() { /bin/sh -c '. "$1/lib.sh"; dsh_dependents_column_check "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
dcroot=$(mktemp -d); mkdir -p "$dcroot/.dsh/.state"
is "dependents column: no map → nothing to say" "rc=0" "$(dcc "$dcroot")"
printf 'core\tcore\ttests\napp\tapp\ttests\n' > "$dcroot/.dsh/.state/modules.tsv"
is "dependents column: three-column map → a note naming the fix" \
  "$(printf 'note\tdownstream tests disabled — the module map has no dependents column; update buildKit/Gate.mill (moduleMapRows) and re-run ./mill moduleMap\nrc=0')" \
  "$(dcc "$dcroot")"
printf 'core\tcore\ttests\tapp\napp\tapp\ttests\t\n' > "$dcroot/.dsh/.state/modules.tsv"
is "dependents column: four-column map → ok" \
  "$(printf 'ok\tthe module map lists each module'"'"'s dependents, so turn-end runs their tests\nrc=0')" \
  "$(dcc "$dcroot")"
rm -rf "$dcroot"
```

- [ ] **Step 2: Run to verify it fails**

Run: `sh kit/harness/tests/lib-test.sh 2>&1 | grep -E 'dependents column|passed'`
Expected: FAIL `dsh_dependents_column_check: not found` in the three rows.

- [ ] **Step 3: Implement** (in `lib.sh`, after `dsh_holdout_checks`)

```sh
# --- the module map's dependents column (spec 2026-10-01 §4) -------------------------------------------
# dsh_dependents_column_check [root]: one `ok|note` TAB <message> row; always exit 0. No map yet → no
# row (other checks already say how to build it). A map where no row has a fourth field → a note: the
# project's Gate.mill predates the dependents column, so turn-end runs only the touched modules' tests —
# today's behaviour, not a broken gate, hence not a FAIL.
dsh_dependents_column_check() {
  _dc_root=${1:-$(gate_root)}
  _dc_map="$_dc_root/.dsh/.state/modules.tsv"
  [ -s "$_dc_map" ] || return 0
  if awk -F'\t' 'NF >= 4 { f = 1 } END { exit !f }' "$_dc_map"; then
    printf 'ok\tthe module map lists each module'"'"'s dependents, so turn-end runs their tests\n'
  else
    printf 'note\tdownstream tests disabled — the module map has no dependents column; update buildKit/Gate.mill (moduleMapRows) and re-run ./mill moduleMap\n'
  fi
  return 0
}
```

In `check-harness.sh`, after the holdout `while … done <<EOF … EOF` block:

```sh
# The module map's dependents column (spec 2026-10-01 §4): same row shape as the holdout rows above.
dc_rows=$(dsh_dependents_column_check "$repo" 2>&1) || :
while IFS="$tab" read -r dc_kind dc_msg; do
  [ -n "$dc_kind" ] || continue
  case "$dc_kind" in
    ok) ok "$dc_msg" ;;
    note) note "$dc_msg" ;;
    *) bad "dsh_dependents_column_check printed a row this check does not understand: $dc_kind $dc_msg" ;;
  esac
done <<EOF
$dc_rows
EOF
```

- [ ] **Step 4: Run to verify it passes** — Run: `for s in sh dash; do $s kit/harness/tests/lib-test.sh 2>&1 | tail -1; done` — Expected: 0 failed under both.

- [ ] **Step 5: Commit**

```bash
git add kit/harness/lib.sh kit/harness/check-harness.sh kit/harness/tests/lib-test.sh
git commit -m "kit(harness): check-harness notes a module map without the dependents column

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

---

### Task 4: `Gate.moduleMapRows` emits the dependents column

**Files:**
- Modify: `kit/recipes/mill/Gate.mill` (`moduleMapRows`, its scaladoc)
- Modify: `kit/recipes/mill.md` (§7 `moduleMap` text and the paragraph at ~line 364)
- Modify: `kit/harness/tests/smoke-second-project.sh:100-103` (row assertions)

**Interfaces:**
- Produces: `moduleMapRows(root, repoRoot, isFormattable, main, scalafix, testCompile, downstreamExcluded: Seq[Module] = Nil): Seq[String]`, rows `<dir>\t<id>\t<caps>\t<dependents>`.

- [ ] **Step 1: Update the smoke assertions first (failing)**

In `smoke-second-project.sh`, change the two `moduleMap` rows to the four-column shape:

```sh
is "moduleMap: core row, no tests capability, no dependents" "$(printf 'core\tcore\tfmt,scalafix\t')" "$(printf '%s\n' "$mm" | awk -F'\t' '$1 == "core"')"
is "moduleMap: exactly core and scalafixRules" "$(printf 'core\tcore\tfmt,scalafix\t\nscalafixRules\tscalafixRules\t\t')" "$mm"
```

- [ ] **Step 2: Run to verify it fails**

Run: `sh kit/harness/tests/smoke-second-project.sh 2>&1 | grep -E 'moduleMap|passed'`
Expected: the two `moduleMap:` rows FAIL (three columns). (Needs real Mill, network and scala-cli; minutes on a cold cache. If the environment cannot run it, record `SKIP smoke: <reason>` in the report and rely on Task 5's real-build check.)

- [ ] **Step 3: Implement in `Gate.mill`**

Signature and body (keep the existing `row`/`rowsOf` structure; add the dependents computation):

```scala
  def moduleMapRows(
      root: Module,
      repoRoot: os.Path,
      isFormattable: Module => Boolean,
      main: Seq[Module],
      scalafix: Seq[Module],
      testCompile: Seq[Module],
      downstreamExcluded: Seq[Module] = Nil
  ): Seq[String] = {
    val fmtIds      = main.map(moduleId).toSet
    val scalafixIds = scalafix.map(moduleId).toSet
    val testIds     = (main ++ testCompile).map(moduleId).toSet
    val excludedIds = downstreamExcluded.map(moduleId).toSet

    def testChild(module: Module): Option[JavaModule] =
      module.moduleDirectChildren.collectFirst {
        case test: TestModule with JavaModule
            if test.moduleSegments.parts.lastOption.contains("test") && testIds.contains(moduleId(test)) => test
      }

    // Every module with the `tests` capability, paired with the ids its test suite compiles against
    // (Mill's own transitive moduleDeps + compileModuleDeps of `<id>.test`, which includes `<id>` itself).
    lazy val suites: Seq[(String, Set[String])] =
      allModules(root).flatMap(m => testChild(m).map(t => moduleId(m) -> t.transitiveModuleCompileModuleDeps.map(moduleId).toSet))

    def dependents(module: Module): String = {
      val id = moduleId(module)
      suites.collect { case (d, deps) if d != id && !excludedIds.contains(d) && deps.contains(id) => d }.sorted.mkString(",")
    }

    def row(module: Module): String = {
      val capabilities =
        (if (fmtIds.contains(moduleId(module))) Seq("fmt") else Nil) ++
          (if (scalafixIds.contains(moduleId(module))) Seq("scalafix") else Nil) ++
          (if (testChild(module).isDefined) Seq("tests") else Nil)
      s"${module.moduleDir.relativeTo(repoRoot)}\t${moduleId(module)}\t${capabilities.mkString(",")}\t${dependents(module)}"
    }
    // rowsOf unchanged
```

with a helper inside `object Gate`:

```scala
  private def allModules(root: Module): Seq[Module] =
    root.moduleDirectChildren.toSeq.flatMap(c => c +: allModules(c))
```

The `tests` capability expression must stay equivalent to the current one (direct child `TestModule` named `test` with its id in `testIds`); `testChild` only factors it out. If `TestModule with JavaModule` does not type-check in a pattern under Mill 1.1.7, match `case test: JavaModule if test.isInstanceOf[TestModule] && …`. Update the scaladoc: four columns, what field 4 means, and the exclusion parameter.

- [ ] **Step 4: Update `mill.md` §7** — the `moduleMap` code block is unchanged in shape (the new parameter has a default); in the prose at ~line 364 add: rows carry a fourth column, the module's dependents with tests; a project passes `downstreamExcluded = Seq(<module>)` for suites that must not gate other modules' turns (nondeterministic or slow ones).

- [ ] **Step 5: Run the smoke to verify it passes** — Run: `sh kit/harness/tests/smoke-second-project.sh 2>&1 | tail -3` — Expected: 0 failed (or the recorded SKIP from Step 2).

- [ ] **Step 6: Commit**

```bash
git add kit/recipes/mill/Gate.mill kit/recipes/mill.md kit/harness/tests/smoke-second-project.sh
git commit -m "kit(recipes): moduleMapRows emits each module's dependents with tests

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

---

### Task 5: Roll out to skreeep2 and check against the measured graph

Repository: `/Users/viktorskalinins/IdeaProjects/skreeep2`. Work on a branch `downstream-turn-end-tests`. Never stage `wiring/arhitecture/src/com/github/mercurievv/skreeep2/wiring/Wiring.scala` unless it carries a real change.

**Files:**
- Modify: `buildKit/Gate.mill` (copy of the template's `kit/recipes/mill/Gate.mill`)
- Modify: `build.mill:771-773` (`moduleMap` call site)
- Modify: `.dsh/engine/**` (re-vendored via the template's `install.sh`)

- [ ] **Step 1: Copy the recipe and pass the exclusion**

`cp <template>/kit/recipes/mill/Gate.mill buildKit/Gate.mill`, then in `build.mill`:

```scala
def moduleMap() = Task.Command {
  println(Gate.moduleMapRows(this, BuildPaths.repoRoot, _.isInstanceOf[Common], mainModules, scalafixModules, testCompileModules, downstreamExcluded = Seq(bench)).mkString("\n"))
}
```

(`bench`'s `UnderrunSpec` real-time budget cases failed in 3 of 3 measured runs, a different 1-3 cases each time.)

- [ ] **Step 2: Check the column against Mill's classpaths (the oracle)**

Run: `./mill --ticker false moduleMap > /tmp/mm.tsv && ./mill --ticker false -j 1 show '__.compileClasspath' > /tmp/cp.json`, then this script, which recomputes dependents from the compile classpaths (the method used for the spec's measurement) and diffs:

```bash
python3 - <<'EOF'
import json,re,collections
cp=json.load(open('/tmp/cp.json'))
rows=[l.split('\t') for l in open('/tmp/mm.tsv').read().splitlines() if l]
assert all(len(r)==4 for r in rows), "every row must have four fields"
tests={r[1] for r in rows if 'tests' in r[2].split(',')}
up={}
for k,v in cp.items():
    m=k[:-len('.compileClasspath')]
    up[m]={re.search(r'/out/(.+?)/compile\.dest/classes',p).group(1).replace('/','.') for p in v if re.search(r'/out/(.+?)/compile\.dest/classes',p)}
bad=0
for d,i,c,deps in rows:
    want=sorted(t for t in tests if t!=i and t!='bench' and i in up.get(t+'.test',set()))
    got=sorted(x for x in deps.split(',') if x)
    if want!=got: bad+=1; print('MISMATCH',i,'want',want,'got',got)
print('rows',len(rows),'mismatches',bad)
EOF
```

Expected: `mismatches 0`, and the `core` row lists 12 modules (13 measured minus `bench`).

- [ ] **Step 3: Re-vendor the engine and regenerate the map**

Run the template's installer the way the last re-vendor did (`sh <template>/kit/harness/install.sh <skreeep2 root>`), then `rm -f .dsh/.state/modules.tsv && sh .dsh/engine/module-map.sh "$PWD/core/src/x.scala"` (any path) to rebuild the cache, then `sh .dsh/engine/check-harness.sh 2>&1 | tail -5`.
Expected: check-harness 0 FAIL, and its output includes `ok   the module map lists each module's dependents, so turn-end runs their tests`.

- [ ] **Step 4: Run the vendored suites**

Run: `sh .dsh/engine/tests/run.sh 2>&1 | tail -2; sh .dsh/engine/tests/frozen-mutations.sh 2>&1 | tail -1`
Expected: 0 failed in both.

- [ ] **Step 5: Commit (skreeep2)**

```bash
git add buildKit/Gate.mill build.mill .dsh/engine
git commit -m "harness: re-vendor engine — turn-end runs dependents' tests; bench excluded from gating others

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

- [ ] **Step 6: Live check (human step — report, do not attempt)**

In the final report give the human these instructions: start a gated Claude session in skreeep2; ask the agent to change a `core` symbol's behaviour in a way a dependent's test catches (e.g. a function in `core` used by `signals` tests); end the turn. Expected: the Stop hook blocks with `turnEndTests: signals (downstream of core) (failed)` and the remedy line.
