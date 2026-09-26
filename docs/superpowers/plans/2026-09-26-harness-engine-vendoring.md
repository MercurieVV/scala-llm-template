# Harness Engine Vendoring (Plan C v2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move skreeep2's DSH harness engine into `scala-llm-template/kit/harness/` as the single source of truth, vendor it into projects as `.dsh/engine/` with a verifiable stamp, ship the Mill tasks it calls as a kit recipe, and make skreeep2 its first consumer.

**Architecture:** The engine (POSIX sh, ~7,800 lines, 332 fixture cases) is copied into the template and taught to find itself relative to its own file rather than at `<repo>/.dsh/`. `install.sh` vendors it wholesale into a project and seeds project state only where absent. `check-harness.sh` and the `health` hook compare the vendored tree with its `STAMP`. The Mill side (`fixStrict`, `fixRanges`, the module-map walk, classpath metadata) moves into `kit/recipes/mill/Gate.mill`; the project keeps a few lines of root tasks over its own module lists.

**Tech Stack:** POSIX `sh` (dash-clean, tested under both `sh` and `dash`), Mill 1.1.8 with mill-scalafix 0.6.2, Scala 3, scala-cli (`Setup.scala`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-09-26-harness-engine-vendoring-design.md`

**Repositories:**

| Short name | Path | Branch for this plan |
|---|---|---|
| template | `/Users/viktorskalinins/IdeaProjects/my/scala-llm-template` | `harness-engine` (worktree) |
| skreeep2 | `/Users/viktorskalinins/IdeaProjects/skreeep2` | `vendor-engine` (worktree) |
| guidelines | `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines` | `master` (docs only, Task 6) |

The engine is imported from skreeep2 **master at `0832f92`**. Below, `$T` is the template worktree root, `$S` the skreeep2 worktree root.

## Global Constraints

- The gate's interface is unchanged: `sh <engine>/gate.sh <sub>`, payload on stdin, exit 0 allow / 2 block; subs `health`, `baseline`, `tool-policy`, `semantic-guard`, `post-edit`, `turn-end`; both wiring dialects (DSH lowercase and Claude Code CamelCase matchers).
- The gate never silently passes: every new condition is a FAIL (check-harness) or a named note. It is never a silent skip.
- Frozen-path semantics are not weakened. Reads of frozen paths stay allowed.
- Engine behaviour changes only by: (a) path moves, (b) the STAMP note in `health`, (c) the non-Mill note plus stand-down in `health`, `post-edit` and `turn-end`.
- `check-harness.sh` stays a host command.
- Every engine script stays POSIX `sh`, with no `local`, no arrays, and no `set -e` in hooks. `dash -n` must be clean.
- Commit messages end with the line `Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX` and carry **no** `Co-Authored-By` trailer.
- In skreeep2, never stage `wiring/arhitecture/src/com/github/mercurievv/skreeep2/wiring/Wiring.scala` unless it carries a real change (the pre-commit hook reformats it).
- Do not edit `$S/.claude/settings.json` or run `./mill installLocal` in ScalaSemanticMCP. Both are human steps.

## Engine layout rule (used by Tasks 1, 2 and 4)

The engine directory is **the same tree** in both places: `$T/kit/harness/` (source) and `<project>/.dsh/engine/` (vendored). Therefore:

- **The engine finds itself from its own file, never from the repository.**
  - A top-level script (`gate.sh`, `lib.sh` callers, `verify-diff.sh`, `module-map.sh`, `check-harness.sh`, `instructions-sync.sh`, `install.sh`) uses `engine=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)`.
  - A hook uses the parent of its own directory.
  - A test script under `tests/` uses `engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)`.
  - Where a script already has such a variable (`here`), keep its name and point it correctly.
- **Project state is found from `gate_root`** (`GATE_ROOT` → `CLAUDE_PROJECT_DIR` → git toplevel → `PWD`), always under `<root>/.dsh/`: `contract`, `frozen-paths`, `policy/`, `instructions/`, `skills/`, `.state/`, `hooks.json`, `cc-settings.json`, `dsh.sh`, `profile/`.
- **Engine files are no longer at `<root>/.dsh/<file>`.** Every `$repo/.dsh/<engine file>`, `$root/.dsh/<engine file>` or literal `.dsh/<engine file>` becomes `$engine/<file>` in code. In comments and user-facing text it becomes `.dsh/engine/<file>`. Engine files are `gate.sh lib.sh verify-diff.sh module-map.sh check-harness.sh instructions-sync.sh install.sh hooks/ tests/ README.md STAMP`.

The residual check, used as an Expected line below. `ENGINE_RE` is the regex for an old-style engine path:

```bash
ENGINE_RE='\.dsh/(gate|lib|verify-diff|module-map|check-harness|instructions-sync)\.sh|\.dsh/hooks/|\.dsh/tests/'
```

## Review Focus

1. **A vendored engine that writes into its own tree.** If any suite that `check-harness.sh` runs from `.dsh/engine/tests` writes a file inside `.dsh/engine/`, then the next check reports "edited in place" on an untouched install. Expected: the stamp still matches after a full `check-harness.sh` run. This is pinned in Task 4 Step 9.
2. **macOS `.DS_Store` inside `.dsh/engine/`.** Finder can create one when someone browses the directory. Expected: it is ignored by the tree hash, not reported as drift. This is pinned in Task 2's `install-test.sh` case `ds_store_ignored`.
3. **Re-install over a project whose state has been tuned.** Expected: every state file is kept byte-identical, and only `.dsh/engine/` changes. This is pinned in Task 2's `reinstall_keeps_state`.
4. **An interrupted install.** If the copy fails part-way, the previous `.dsh/engine/` must still be in place and complete. Expected: no half-written engine is ever at the live path. This is pinned in Task 2's `failed_copy_keeps_old_engine`.
5. **A Mill project whose root has no `build.mill` in fixture form, or a Mill project missing its wrapper.** Expected: the existing behaviour, not the non-Mill stand-down. The non-Mill rule fires only on positive evidence of another build tool. This is pinned in Task 2's fixture `turn-end-mill-no-wrapper-still-blocks`, and by the unchanged suite of 332 cases.

## Rulings made while writing this plan

- **Non-Mill detection is positive.** A project is non-Mill when `build.sbt` or `project.scala` exists at the root **and** neither `build.mill` nor an executable `mill` wrapper does. Measured: 48 of 93 existing turn-end, post-edit, rewrite, memo and verify fixtures have no `build.mill` (they rely on the `mill` stub on PATH), so "no build.mill" cannot mean "not Mill". The spec's `found: none` case therefore stays on today's behaviour (Mill assumed; a missing wrapper still blocks). Cost if wrong: an unrecognised third build tool, such as Gradle, is treated as Mill and blocks with "no Mill". That is loud, not silent.
- **Unmapped `.scala` paths.** Today, turn-end skips a path whose module-map lookup is `-` (`turn-end.sh`: `[ "$lookup" = "-" ] && continue`). Spec §4.5's "stands down by name" would be a behaviour change, and the spec's invariants exclude those. The smoke test asserts today's contract instead: exit 0, and no Mill task is run for that path. The engine README's blind-spot list names the gap. Cost if wrong: one follow-up to add a note line.
- **`STAMP` checks apply only to a vendored engine**, meaning one whose physical path is `<root>/.dsh/engine`. The template's own test runs execute an unstamped `kit/harness/` against scratch roots, and must not produce a note on every fixture.

---

### Task 1: Import the engine into `kit/harness/`, relocated

**Files:**
- Create: `$T/kit/harness/{gate.sh,lib.sh,verify-diff.sh,module-map.sh,check-harness.sh,instructions-sync.sh}`, `$T/kit/harness/hooks/*.sh` (7 files), and `$T/kit/harness/tests/**`, which is everything under `$S/.dsh/tests/` **except** `wiring-test.sh` and `committed-tree-test.sh`. Those two read the project's own wiring and clone the project; they stay in skreeep2 (Task 4).
- Modify: the copied files only, per the Engine layout rule.

**Interfaces:**
- Consumes: skreeep2 `.dsh/` at `0832f92`.
- Produces: an engine that runs from any directory. `engine` is the variable naming its root in every script. `check-harness.sh` takes an optional `--project <dir>` (default: `gate_root`), plus its existing `--full`. Later tasks rely on `$engine/tests/run.sh` running every case with no project present.

- [ ] **Step 1: Create the worktree and copy the engine verbatim**

```bash
cd /Users/viktorskalinins/IdeaProjects/my/scala-llm-template
git worktree add -b harness-engine ../scala-llm-template-harness-engine master
T=/Users/viktorskalinins/IdeaProjects/my/scala-llm-template-harness-engine
SRC=/Users/viktorskalinins/IdeaProjects/skreeep2
test "$(git -C $SRC rev-parse --short master)" = 0832f92 || echo "skreeep2 master moved: record the new sha as the import source"
mkdir -p $T/kit/harness
X=$(mktemp -d) && git -C $SRC archive master .dsh | tar -x -C "$X"
I=$X/.dsh
ENGINE_RE='\.dsh/(gate|lib|verify-diff|module-map|check-harness|instructions-sync)\.sh|\.dsh/hooks/|\.dsh/tests/'
cp $I/gate.sh $I/lib.sh $I/verify-diff.sh $I/module-map.sh $I/check-harness.sh $I/instructions-sync.sh $T/kit/harness/
cp -R $I/hooks $T/kit/harness/hooks
cp -R $I/tests $T/kit/harness/tests
rm $T/kit/harness/tests/wiring-test.sh $T/kit/harness/tests/committed-tree-test.sh
find $T/kit/harness -type f | wc -l
```

Expected: the file count is printed. `git archive` takes the **committed** tree, so no untracked or ignored files come along.

- [ ] **Step 2: Commit the verbatim copy on its own** (so the relocation diff is reviewable separately)

```bash
cd $T && git add kit/harness && git commit -q -m "kit(harness): import the DSH engine verbatim from skreeep2 0832f92

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

- [ ] **Step 3: Run the suite to see it fail for the expected reason**

Run: `cd $T && sh kit/harness/tests/run.sh 2>&1 | tail -5`
Expected: failures, or an immediate error, because `run.sh` resolves `repo=<dirname>/../..` = `$T/kit` and looks for `$T/kit/.dsh/tests/cases`. This is the RED for Step 4.

- [ ] **Step 4: Apply the Engine layout rule to every copied file**

List the sites:

```bash
cd $T/kit/harness && grep -rnE "$ENGINE_RE" . --include='*.sh' | grep -v '/cases/' | wc -l
grep -rnE '\$(repo|root|here)/\.\.|/\.\./\.\.' . --include='*.sh' | grep -v '/cases/'
```

Rewrite each site by the rule:

- `tests/*.sh`: replace `repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)` with `engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)`, then `$repo/.dsh/<engine file>` with `$engine/<file>`.
- `check-harness.sh`: set `engine` from its own path. Parse `--project <dir>` next to `--full` (the usage text lists both). Set `repo` to that directory, else `gate_root`. Engine paths use `$engine/…`; project-state paths stay `$repo/.dsh/…`.
  - Group D's suite discovery runs `"$engine"/tests/*-test.sh` and `$engine/tests/run.sh`, then `"$repo"/.dsh/tests/*-test.sh` when that directory exists.
  - The opt-in suite name `committed-tree-test.sh` is looked up under `$repo/.dsh/tests/`.
  - Group B's "every command names this repository's gate.sh" check compares against `$repo/.dsh/engine/gate.sh`.
- Hooks and top-level scripts: any `$root/.dsh/<engine file>` or `"$here/…"` that meant the engine becomes `$engine/…`.
- Fixture cases under `tests/cases/*/`: they carry project state in `root/.dsh/…`, and that stays. A case whose `payload.json`, `env`, `pre_gate` or `post_gate` names an engine file is rewritten to `SCRATCH_ROOT`-independent engine paths only if it fails in Step 5.
- `frozen-mutations.sh` builds a scratch tree holding `.dsh/`. Make it copy the engine to `$tree/.dsh/engine/` and run `$tree/.dsh/engine/tests/run.sh`, so the mutated copy is a vendored layout.
- `lib-test.sh` lines that embed skreeep2 test output (e.g. `SmokeHoldout`, `CaptureProps` paths) are parser inputs, not paths the engine reads. Leave them.

- [ ] **Step 5: Run the residual check and the suites under both shells**

Run:
```bash
cd $T/kit/harness && grep -rnE "$ENGINE_RE" . --include='*.sh' | grep -v '/cases/' | grep -v '\.dsh/engine/'
for f in $(find . -name '*.sh' ! -path '*/cases/*'); do dash -n "$f" || echo "DASH-N FAIL $f"; done
sh tests/run.sh > /tmp/he-run-sh.log 2>&1; tail -3 /tmp/he-run-sh.log
dash tests/run.sh > /tmp/he-run-dash.log 2>&1; tail -3 /tmp/he-run-dash.log
for s in tests/*-test.sh; do sh "$s" > /tmp/he-$(basename $s).log 2>&1; echo "$s exit $?"; done
```

Expected:
- the residual grep prints nothing;
- there are no `DASH-N FAIL` lines;
- both `run.sh` runs end with `0 failed`, and the passed count equals the number of directories in `tests/cases`;
- every `*-test.sh` exits 0.

Any case that fails only because it hard-codes a skreeep2 path gets fixed to be self-contained. Ledger each one as `Task 1: Ruling: <case> — <what it assumed> — <fix>`.

- [ ] **Step 6: Commit**

```bash
cd $T && git add kit/harness && git commit -q -m "kit(harness): the engine finds itself from its own file; project state from gate_root

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

---

### Task 2: `install.sh`, `STAMP`, drift checks, and the non-Mill stand-down

**Files:**
- Create: `$T/kit/harness/install.sh`, `$T/kit/harness/tests/install-test.sh`, and `$T/kit/harness/seed/{contract,frozen-paths,hooks.json,cc-settings.json,policy/allowed-types.tsv,policy/memorisation.tsv,instructions/local.tsv,instructions/scalac-kinds.tsv}`
- Create fixtures: `$T/kit/harness/tests/cases/{health-non-mill-note,turn-end-non-mill-stands-down,post-edit-non-mill-stands-down,turn-end-mill-no-wrapper-still-blocks}/`
- Modify: `$T/kit/harness/lib.sh` (new helpers), `hooks/health.sh`, `hooks/turn-end.sh`, `hooks/post-edit.sh`, `check-harness.sh` (a new group G)

**Interfaces:**
- Consumes: Task 1's `engine` variable convention, and `lib.sh`'s `dsh_has_hasher`.
- Produces:
  - `sh <engine>/install.sh <project>`. Exit codes: 0 installed; 1 usage/not a dir; 2 not a git repo; 3 no hasher; 4 copy failed.
  - `dsh_engine_tree_hash <dir>`, which prints a sha256 hex or `-`.
  - `dsh_engine_stamp_verdict <dir>`, which prints `ok`, `missing`, `mismatch` or `nohasher`.
  - `dsh_engine_stamp_field <dir> <key>`, which prints a value or nothing.
  - `dsh_is_vendored_engine <engine> <root>`, which exits 0 iff the physical paths are equal.
  - `dsh_non_mill_build <root>`, which prints `build.sbt` or `project.scala` and exits 0 when the project is non-Mill (see the ruling), and exits 1 otherwise.

- [ ] **Step 1: Write the seed files**

`seed/contract`:
```
# The project's gate interface (see .dsh/engine/README.md). The engine never learns a build tool's name
# beyond Mill's task names: it runs these. Optional keys: holdout, fastTests, turnEndTests.
preCommit   = ./mill -j 1 preCommit
prePush     = ./mill -j 1 prePush
checkFormat = ./mill -j 1 --ticker false <module>.checkFormat
fix         = ./mill -j 1 --ticker false <module>.fix --check
coverage    = ./mill -j 1 --ticker false moduleMap
roots       = .
```

`seed/frozen-paths`. Columns are separated by a single TAB, the same format as `$SRC/.dsh/frozen-paths`. Copy that file's header comment block verbatim above these rows:
```
.dsh/engine/**	the engine is vendored from scala-llm-template/kit/harness; edit it there and re-run install.sh
.dsh/frozen-paths	the freeze list is the human's; ask in chat to unfreeze
.dsh/contract	the gate interface is the human's
.dsh/hooks.json	the hook wiring is the human's
.dsh/cc-settings.json	the hook wiring Claude Code actually reads; the human's
.claude/settings.json	the hook wiring Claude Code actually reads; the human's
.claude/settings.local.json	the hook wiring Claude Code actually reads; the human's
.dsh/.state/receipts	receipts are the gate's record; the human's
.dsh/.state/modules.tsv	the coverage map is the build's answer; edit build.mill, not this cache
.dsh/instructions/local.tsv	the project's instruction table; the agent proposes rows in chat, the human writes them
.dsh/instructions/scalac-kinds.tsv	the scalac headline→kind table; the human's
.dsh/policy/allowed-types.tsv	the module policy is the human's: an agent that may widen its own allowlist has none
.dsh/policy/memorisation.tsv	the memorisation thresholds and exemptions are the human's: an agent may not exempt its own reward hacking
```

`seed/hooks.json` and `seed/cc-settings.json`: copy `$SRC/.dsh/hooks.json` and `$SRC/.dsh/cc-settings.json`, replacing every `/.dsh/gate.sh` with `/.dsh/engine/gate.sh`:

```bash
sed 's#/\.dsh/gate\.sh#/.dsh/engine/gate.sh#g' $SRC/.dsh/hooks.json > $T/kit/harness/seed/hooks.json
sed 's#/\.dsh/gate\.sh#/.dsh/engine/gate.sh#g' $SRC/.dsh/cc-settings.json > $T/kit/harness/seed/cc-settings.json
grep -c 'engine/gate.sh' $T/kit/harness/seed/hooks.json $T/kit/harness/seed/cc-settings.json
```
Expected: 6 in each (one per hook command).

The policy and instruction seeds are header comments only, because rows are project decisions:

```bash
mkdir -p $T/kit/harness/seed/policy $T/kit/harness/seed/instructions
grep '^#' $SRC/.dsh/policy/allowed-types.tsv > $T/kit/harness/seed/policy/allowed-types.tsv
grep '^#' $SRC/.dsh/policy/memorisation.tsv > $T/kit/harness/seed/policy/memorisation.tsv
grep '^#' $SRC/.dsh/instructions/local.tsv > $T/kit/harness/seed/instructions/local.tsv
cp $SRC/.dsh/instructions/scalac-kinds.tsv $T/kit/harness/seed/instructions/scalac-kinds.tsv
```

`scalac-kinds.tsv` is copied whole: it maps compiler headlines to kinds and is not project-specific.

- [ ] **Step 2: Write the failing `tests/install-test.sh`**

It follows the house style of `tests/module-map-test.sh`: an `is <label> <expected> <actual>` helper, pass/fail counters, and a non-zero exit on any failure. Each case builds its own scratch repository under `mktemp -d`.

```sh
#!/bin/sh
# install.sh and the engine stamp (spec 2026-09-26 §2): vendoring replaces the engine wholesale, seeds
# project state only where absent, and the stamp detects an engine edited in place.
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$engine/lib.sh"
passed=0; failed=0
is() { if [ "$2" = "$3" ]; then passed=$((passed+1)); printf 'ok   %s\n' "$1"; else failed=$((failed+1)); printf 'FAIL %s\n     want [%s]\n     got  [%s]\n' "$1" "$2" "$3"; fi; }
scratch() { _d=$(mktemp -d); git -C "$_d" init -q; printf '%s\n' "$_d"; }

# fresh_install_seeds: every seed lands, the engine lands with a STAMP, verdict ok.
p=$(scratch)
out=$(sh "$engine/install.sh" "$p" 2>&1); code=$?
is "fresh_install_seeds: exit" 0 "$code"
for f in contract frozen-paths hooks.json cc-settings.json policy/allowed-types.tsv policy/memorisation.tsv instructions/local.tsv instructions/scalac-kinds.tsv; do
  is "fresh_install_seeds: seeded $f" yes "$([ -f "$p/.dsh/$f" ] && echo yes || echo no)"
done
is "fresh_install_seeds: engine gate" yes "$([ -f "$p/.dsh/engine/gate.sh" ] && echo yes || echo no)"
is "fresh_install_seeds: no seed/ inside the engine" no "$([ -e "$p/.dsh/engine/seed" ] && echo yes || echo no)"
is "fresh_install_seeds: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"
is "fresh_install_seeds: says seeded" yes "$(printf '%s\n' "$out" | grep -q '^seeded .*contract' && echo yes || echo no)"

# reinstall_keeps_state: tuned state survives byte-for-byte; the engine is replaced.
printf 'roots = src\n' >> "$p/.dsh/contract"; before=$(dsh_file_hash "$p/.dsh/contract")
printf 'junk\n' > "$p/.dsh/engine/stale-file"
out=$(sh "$engine/install.sh" "$p" 2>&1)
is "reinstall_keeps_state: contract unchanged" "$before" "$(dsh_file_hash "$p/.dsh/contract")"
is "reinstall_keeps_state: says kept" yes "$(printf '%s\n' "$out" | grep -q '^kept .*contract' && echo yes || echo no)"
is "reinstall_keeps_state: stale engine file gone" no "$([ -e "$p/.dsh/engine/stale-file" ] && echo yes || echo no)"
is "reinstall_keeps_state: says replaced" yes "$(printf '%s\n' "$out" | grep -q '^replaced .*\.dsh/engine' && echo yes || echo no)"

# edited_in_place: one byte in the vendored engine flips the verdict.
printf '\n' >> "$p/.dsh/engine/lib.sh"
is "edited_in_place: verdict" mismatch "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# stamp_missing
sh "$engine/install.sh" "$p" >/dev/null 2>&1; rm "$p/.dsh/engine/STAMP"
is "stamp_missing: verdict" missing "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# ds_store_ignored
sh "$engine/install.sh" "$p" >/dev/null 2>&1; : > "$p/.dsh/engine/.DS_Store"; : > "$p/.dsh/engine/hooks/.DS_Store"
is "ds_store_ignored: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# stamp_fields: template sha is 40 hex (or `unknown`), dirty is 0|1
tpl=$(dsh_engine_stamp_field "$p/.dsh/engine" template)
is "stamp_fields: template shape" yes "$(printf '%s' "$tpl" | grep -Eq '^([0-9a-f]{40}|unknown)$' && echo yes || echo no)"
is "stamp_fields: dirty shape" yes "$(dsh_engine_stamp_field "$p/.dsh/engine" dirty | grep -Eq '^[01]$' && echo yes || echo no)"

# not_a_git_repo
d=$(mktemp -d); sh "$engine/install.sh" "$d" >/dev/null 2>&1
is "not_a_git_repo: exit" 2 "$?"
is "not_a_git_repo: nothing written" no "$([ -e "$d/.dsh" ] && echo yes || echo no)"

# usage
sh "$engine/install.sh" >/dev/null 2>&1; is "usage: exit" 1 "$?"

# failed_copy_keeps_old_engine: a copy that fails leaves the previous engine complete at the live path.
p2=$(scratch); sh "$engine/install.sh" "$p2" >/dev/null 2>&1
v_before=$(dsh_file_hash "$p2/.dsh/engine/STAMP")
DSH_INSTALL_FAIL_COPY=1 sh "$engine/install.sh" "$p2" >/dev/null 2>&1; code=$?
is "failed_copy_keeps_old_engine: exit" 4 "$code"
is "failed_copy_keeps_old_engine: STAMP unchanged" "$v_before" "$(dsh_file_hash "$p2/.dsh/engine/STAMP")"
is "failed_copy_keeps_old_engine: verdict" ok "$(dsh_engine_stamp_verdict "$p2/.dsh/engine")"
is "failed_copy_keeps_old_engine: no temp dirs left" "" "$(ls -a "$p2/.dsh" | grep '^\.engine\.' || true)"

# vendored_detection
is "vendored_detection: vendored" 0 "$(dsh_is_vendored_engine "$p/.dsh/engine" "$p"; echo $?)"
is "vendored_detection: source tree" 1 "$(dsh_is_vendored_engine "$engine" "$p"; echo $?)"

# non_mill_detection (the positive-evidence ruling)
n=$(mktemp -d); : > "$n/build.sbt"
is "non_mill_detection: sbt" build.sbt "$(dsh_non_mill_build "$n")"
: > "$n/build.mill"; is "non_mill_detection: sbt+mill is Mill" 1 "$(dsh_non_mill_build "$n" >/dev/null; echo $?)"
e=$(mktemp -d); is "non_mill_detection: empty root is not non-Mill" 1 "$(dsh_non_mill_build "$e" >/dev/null; echo $?)"
s=$(mktemp -d); : > "$s/project.scala"; is "non_mill_detection: scala-cli" project.scala "$(dsh_non_mill_build "$s")"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
```

`DSH_INSTALL_FAIL_COPY` is a test seam in `install.sh`, in the same spirit as `GATE_ROOT`: when it is set, the copy step fails after the new tree is partly built.

- [ ] **Step 3: Run it; expect RED**

Run: `sh $T/kit/harness/tests/install-test.sh | tail -3`
Expected: FAIL lines. `install.sh` does not exist, and the `dsh_engine_*` functions are undefined (`not found`).

- [ ] **Step 4: Add the `lib.sh` helpers** (after `dsh_file_hash`)

```sh
# sha256 of stdin, hex only. Callers check dsh_has_hasher first.
dsh_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

# The engine's tree hash (spec 2026-09-26 §2): sha256 over the sorted relative file list and each file's
# bytes, the top-level STAMP and every .DS_Store excluded. `-` when there is no hasher.
dsh_engine_tree_hash() {
  dsh_has_hasher || { printf '%s\n' '-'; return 0; }
  ( cd "$1" 2>/dev/null || exit 1
    find . -type f ! -path ./STAMP ! -name .DS_Store | LC_ALL=C sort | while IFS= read -r _f; do
      printf '%s\n' "$_f"; cat "$_f"
    done ) | dsh_sha256_stdin
}

# One field of <engine>/STAMP, or nothing.
dsh_engine_stamp_field() {
  [ -f "$1/STAMP" ] || return 0
  sed -n "s/^$2=//p" "$1/STAMP" | head -1
}

# ok | missing | mismatch | nohasher
dsh_engine_stamp_verdict() {
  [ -f "$1/STAMP" ] || { printf 'missing\n'; return 0; }
  dsh_has_hasher || { printf 'nohasher\n'; return 0; }
  if [ "$(dsh_engine_stamp_field "$1" tree)" = "$(dsh_engine_tree_hash "$1")" ]; then printf 'ok\n'; else printf 'mismatch\n'; fi
}

# Is <engine> the vendored copy of <root>, i.e. physically <root>/.dsh/engine? The template's own runs are not.
dsh_is_vendored_engine() {
  _ve=$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd) || return 1
  _vr=$(CDPATH= cd -P -- "$2/.dsh/engine" 2>/dev/null && pwd) || return 1
  [ "$_ve" = "$_vr" ]
}

# Positive evidence of a non-Mill build (plan ruling): build.sbt or project.scala at the root, and neither
# build.mill nor an executable ./mill. Prints which file; exit 1 when the project is (or may be) Mill.
dsh_non_mill_build() {
  { [ -e "$1/build.mill" ] || [ -x "$1/mill" ]; } && return 1
  [ -e "$1/build.sbt" ] && { printf 'build.sbt\n'; return 0; }
  [ -e "$1/project.scala" ] && { printf 'project.scala\n'; return 0; }
  return 1
}
```

- [ ] **Step 5: Write `install.sh`**

```sh
#!/bin/sh
# Vendor this engine into <project>/.dsh/engine/ and seed the project's gate state (spec 2026-09-26 §2).
#   sh kit/harness/install.sh <project>
# The engine is replaced wholesale (built beside the live copy, then renamed in); project state is seeded
# only where absent and never overwritten. One line per file: seeded | kept | replaced.
# Exit 0 installed; 1 usage or not a directory; 2 not a git repository; 3 no sha256 tool; 4 copy failed.
set -u
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$src/lib.sh"
[ "$#" -eq 1 ] || { printf 'usage: sh %s <project>\n' "$0" >&2; exit 1; }
dst=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || { printf 'install: %s is not a directory\n' "$1" >&2; exit 1; }
git -C "$dst" rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'install: %s is not a git repository\n' "$dst" >&2; exit 2; }
dsh_has_hasher || { printf 'install: no sha256 tool (shasum or sha256sum) -- the stamp cannot be written\n' >&2; exit 3; }

tpl=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || tpl=""
sha=unknown; dirty=0
if [ -n "$tpl" ]; then
  sha=$(git -C "$tpl" rev-parse HEAD 2>/dev/null) || sha=unknown
  [ -n "$(git -C "$tpl" status --porcelain -- "$src" 2>/dev/null)" ] && dirty=1
fi

mkdir -p "$dst/.dsh" || exit 4
new="$dst/.dsh/.engine.new.$$"; old="$dst/.dsh/.engine.old.$$"
trap 'rm -rf "$new" "$old"' EXIT INT TERM
fail() { printf 'install: %s -- the live .dsh/engine is untouched\n' "$1" >&2; exit 4; }
mkdir "$new" || fail "cannot create $new"
cp -R "$src/." "$new/" || fail "copy into $new failed"
[ -n "${DSH_INSTALL_FAIL_COPY:-}" ] && fail "copy failed (DSH_INSTALL_FAIL_COPY test seam)"
rm -rf "$new/seed" "$new/STAMP"
find "$new" -name .DS_Store -type f -exec rm -f {} + 2>/dev/null
printf 'template=%s\ndirty=%s\ntree=%s\n' "$sha" "$dirty" "$(dsh_engine_tree_hash "$new")" > "$new/STAMP" || fail "cannot write STAMP"

if [ -d "$dst/.dsh/engine" ]; then
  mv "$dst/.dsh/engine" "$old" || fail "cannot move the old engine aside"
  if ! mv "$new" "$dst/.dsh/engine"; then mv "$old" "$dst/.dsh/engine"; fail "cannot move the new engine in"; fi
  printf 'replaced .dsh/engine (template %s%s)\n' "$sha" "$([ "$dirty" = 1 ] && echo ', dirty')"
else
  mv "$new" "$dst/.dsh/engine" || fail "cannot move the new engine in"
  printf 'seeded   .dsh/engine (template %s%s)\n' "$sha" "$([ "$dirty" = 1 ] && echo ', dirty')"
fi

for rel in contract frozen-paths hooks.json cc-settings.json policy/allowed-types.tsv policy/memorisation.tsv instructions/local.tsv instructions/scalac-kinds.tsv; do
  if [ -e "$dst/.dsh/$rel" ]; then
    printf 'kept     .dsh/%s\n' "$rel"
  else
    mkdir -p "$(dirname "$dst/.dsh/$rel")" && cp "$src/seed/$rel" "$dst/.dsh/$rel" || { printf 'install: cannot seed .dsh/%s\n' "$rel" >&2; exit 4; }
    printf 'seeded   .dsh/%s\n' "$rel"
  fi
done
exit 0
```

- [ ] **Step 6: Run `install-test.sh`; expect GREEN**

Run: `sh $T/kit/harness/tests/install-test.sh | tail -1 && dash $T/kit/harness/tests/install-test.sh | tail -1`
Expected: `N passed, 0 failed` under both shells.

- [ ] **Step 7: Write the four RED fixture cases**

These use `run.sh`'s case format: `payload.json`, `expect.code`, `expect.grep`, `root/`, `git_init`, `post_git`. Model each on an existing case of the same hook. List with `ls tests/cases | grep '^turn-end-' | head` and copy the nearest one's `payload.json`.

- `health-non-mill-note`: `root/build.sbt` (empty), a SessionStart payload copied from an existing `health-*` case. `expect.code` = `0`. `expect.grep`: `gate engine supports Mill builds only; found: build.sbt -- checks stand down`
- `turn-end-non-mill-stands-down`: `root/build.sbt`, `root/src/A.scala` (`object A`), `git_init`, and a `post_git` that appends a line to `src/A.scala`. Stop payload. `expect.code` = `0`. `expect.grep`: `gate engine supports Mill builds only; found: build.sbt`. `expect.millcalls` = `0`.
- `post-edit-non-mill-stands-down`: `root/build.sbt`, `root/src/A.scala`, and a PostToolUse Write payload naming `SCRATCH_ROOT/src/A.scala`. `expect.code` = `0`, the same grep, `expect.millcalls` = `0`.
- `turn-end-mill-no-wrapper-still-blocks`: copy the existing case whose `expect.grep` contains `there is no Mill to run the checks with` (find it with `grep -l 'no Mill to run' tests/cases/*/expect.grep`), unchanged except for the name, plus an empty `root/build.mill`. `expect.code` = `2`. This pins Review Focus 5.

Run: `sh $T/kit/harness/tests/run.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: the three `*-non-mill-*` cases FAIL; `turn-end-mill-no-wrapper-still-blocks` passes (today's behaviour).

- [ ] **Step 8: Implement the notes and the stand-down**

`hooks/health.sh`, immediately before the final `exit 0`:

```sh
# --- the engine's own provenance and the build tool (spec 2026-09-26 §2, §3) -----------------------
# Printed as separate note lines, never folded into `notes=` (whose caps belong to doctor and coverage).
# Only a vendored engine has a stamp to compare; the template's own runs are not vendored.
eng=$(CDPATH= cd -- "$here/.." && pwd)
if dsh_is_vendored_engine "$eng" "$root"; then
  sv=$(dsh_engine_stamp_verdict "$eng")
  [ "$sv" = ok ] || printf 'DSH harness: note -- vendored engine does not match its stamp (%s); run sh .dsh/engine/check-harness.sh\n' "$sv"
fi
if nm=$(dsh_non_mill_build "$root"); then
  printf 'DSH harness: note -- gate engine supports Mill builds only; found: %s -- checks stand down\n' "$nm"
fi
```

(If `health.sh` names its own directory differently from `here`, use that variable. Check with `grep -n '^here=' hooks/health.sh`.)

`hooks/turn-end.sh` and `hooks/post-edit.sh`: immediately **before** the `mill=$(resolve_mill "$root") || mill=""` line, add:

```sh
# A project with positive evidence of another build tool (plan ruling, spec §3): the engine's checks are
# Mill tasks, so it stands down, named, instead of blocking on "no Mill".
if nm=$(dsh_non_mill_build "$root"); then
  allow "DSH gate: gate engine supports Mill builds only; found: $nm -- checks stand down for this turn"
fi
```

In `post-edit.sh`, use that hook's existing non-blocking exit with a message. Find it with `grep -n '^allow\|allow()' hooks/post-edit.sh lib.sh`. If post-edit has no `allow`, print the same line to stderr and `exit 0`. Ledger which form was used.

- [ ] **Step 9: Add check-harness group G**

After group F, add:

```sh
# G. the vendored engine (spec 2026-09-26 §2) -- the engine is edited in scala-llm-template/kit/harness and
#    vendored by install.sh; a tree that no longer matches its STAMP was edited in place.
if dsh_is_vendored_engine "$engine" "$repo"; then
  case $(dsh_engine_stamp_verdict "$engine") in
    ok)       ok "vendored engine matches its STAMP (template $(dsh_engine_stamp_field "$engine" template))" ;;
    missing)  bad "$engine/STAMP is missing -- re-run sh <scala-llm-template>/kit/harness/install.sh $repo" ;;
    mismatch) bad "vendored engine edited in place; edit in scala-llm-template/kit/harness and re-run install.sh" ;;
    nohasher) bad "no sha256 tool (shasum or sha256sum): the vendored engine cannot be compared with its STAMP" ;;
  esac
  [ "$(dsh_engine_stamp_field "$engine" dirty)" = 1 ] && note "the engine was vendored from an uncommitted template (STAMP dirty=1)"
  if [ -n "${SCALA_LLM_TEMPLATE:-}" ] && [ -d "$SCALA_LLM_TEMPLATE/kit/harness" ]; then
    th=$(dsh_engine_tree_hash "$SCALA_LLM_TEMPLATE/kit/harness")
    # The template's tree includes seed/ and has no STAMP; hash a vendored-shaped copy to compare like for like.
    tmpv=$(mktemp -d) && cp -R "$SCALA_LLM_TEMPLATE/kit/harness/." "$tmpv/" && rm -rf "$tmpv/seed" \
      && th=$(dsh_engine_tree_hash "$tmpv"); rm -rf "$tmpv"
    [ "$th" = "$(dsh_engine_stamp_field "$engine" tree)" ] || note "the template at \$SCALA_LLM_TEMPLATE has moved ahead of the vendored engine -- re-run its install.sh to take it"
  fi
else
  note "check run from an unvendored engine at $engine -- no STAMP to compare (this is the template's own tree)"
fi
```

Add a line for G to the header's group list.

- [ ] **Step 10: GREEN**

Run:
```bash
cd $T/kit/harness && sh tests/run.sh > /tmp/he2.log 2>&1; tail -2 /tmp/he2.log; dash tests/run.sh > /tmp/he2d.log 2>&1; tail -2 /tmp/he2d.log
for s in tests/*-test.sh; do sh "$s" > /dev/null 2>&1 || echo "RED $s"; done
for f in $(find . -name '*.sh' ! -path '*/cases/*'); do dash -n "$f" || echo "DASH-N FAIL $f"; done
```
Expected: `0 failed` twice, with the passed count at Task 1's count plus 4; no `RED` lines; no `DASH-N FAIL`.

- [ ] **Step 11: Commit**

```bash
cd $T && git add kit/harness && git commit -q -m "kit(harness): install.sh vendors the engine with a STAMP; drift is a check-harness FAIL; non-Mill builds stand down, named

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

---

### Task 3: `Gate.mill` and the recipe's "gate's tasks" section

**Files:**
- Create: `$T/kit/recipes/mill/Gate.mill`
- Modify: `$T/kit/recipes/mill.md` (a new section `## 7. The gate's tasks`, inserted after `## 6. Run it` and before `## What this does not decide (R-11)`)
- Modify: `$T/Setup.scala` (InstallKit's Mill branch also vendors `buildKit/Gate.mill`, next to `buildKit/ArchitectureShapeModule.mill` at the `writeVendored("buildKit/ArchitectureShapeModule.mill", helper)` line)

**Interfaces:**
- Consumes: skreeep2 `buildKit/Layer.mill` lines 31–156 (the `fixStrict` doc comment through the end of `fixRanges`), and `build.mill`'s `moduleMap` body and `object ScalaSemanticClasspathMetadata`.
- Produces:
  - `trait GateLayer extends ScalafixModule`, carrying `def fixStrict: T[Unit]` and `def fixRanges(rangesFile: String): Command[Unit]`.
  - `object Gate` with `def moduleId(module: Module): String`, `def moduleMapRows(root: Module, repoRoot: os.Path, isFormattable: Module => Boolean, main: Seq[Module], scalafix: Seq[Module], testCompile: Seq[Module]): Seq[String]` (sorted), and a nested `object ClasspathMetadata` holding `Module`, `metadataPath`, `render`, `writeIfChanged`, `pathString` and `jsonString` exactly as in skreeep2.
  - It imports `build.BuildPaths`, which the recipe's §1 fragment already defines.

- [ ] **Step 1: Write `Gate.mill`**

```scala
package build.buildKit

import mill._
import mill.scalalib._
import com.goyeau.mill.scalafix.ScalafixModule
import scala.jdk.CollectionConverters.*
import scala.jdk.OptionConverters.*
import build.BuildPaths

/** The Mill side of the harness engine's interface (scala-llm-template kit/harness, spec 2026-09-26 §3). The engine
  * runs these by name: `<module>.fixStrict`, `<module>.fixRanges --rangesFile <path>`, and the root tasks the recipe's
  * §7 writes over `Gate`'s helpers (`moduleMap`, `scalaSemanticWriteClasspath`, `preCommit`, `prePush`).
  */
trait GateLayer extends ScalafixModule {
  // ── moved verbatim from skreeep2 buildKit/Layer.mill lines 31–156: the fixStrict doc + body, the fixRanges doc + body
}

object Gate {
  def moduleId(module: Module): String = module.moduleSegments.parts.mkString(".")

  /** `<dir>\t<module id>\t<capabilities>` per module, sorted — the format `.dsh/engine/module-map.sh` reads. The rows
    * come from walking the module tree, so a module added to the build cannot silently drop out of the map. A module
    * `isFormattable` accepts gets a row; so does any other `JavaModule` that is not a `TestModule`. Capabilities:
    * `fmt` (in `main`), `scalafix` (in `scalafix`), `tests` (a direct child `TestModule` named `test` that is in
    * `main ++ testCompile`, so `<id>.test.compile` resolves).
    */
  def moduleMapRows(
      root: Module,
      repoRoot: os.Path,
      isFormattable: Module => Boolean,
      main: Seq[Module],
      scalafix: Seq[Module],
      testCompile: Seq[Module]
  ): Seq[String] = {
    val fmtIds      = main.map(moduleId).toSet
    val scalafixIds = scalafix.map(moduleId).toSet
    val testIds     = (main ++ testCompile).map(moduleId).toSet

    def row(module: Module): String = {
      val capabilities =
        (if (fmtIds.contains(moduleId(module))) Seq("fmt") else Nil) ++
          (if (scalafixIds.contains(moduleId(module))) Seq("scalafix") else Nil) ++
          (if (
             module.moduleDirectChildren.exists {
               case test: TestModule =>
                 test.moduleSegments.parts.lastOption.contains("test") && testIds.contains(moduleId(test))
               case _ => false
             }
           ) Seq("tests")
           else Nil)
      s"${module.moduleDir.relativeTo(repoRoot)}\t${moduleId(module)}\t${capabilities.mkString(",")}"
    }

    def rowsOf(module: Module): Seq[String] =
      module.moduleDirectChildren.toSeq.flatMap { child =>
        val own =
          if (isFormattable(child)) Some(row(child))
          else
            child match {
              case _: TestModule          => None
              case compilable: JavaModule => Some(row(compilable))
              case _                      => None
            }
        own.toSeq ++ rowsOf(child)
      }

    rowsOf(root).sorted
  }

  /** The `classpath-mill.json` format the ScalaSemantic server reads. */
  object ClasspathMetadata {
    // ── moved verbatim from skreeep2 build.mill `object ScalaSemanticClasspathMetadata { … }` body
  }
}
```

Fill the two `── moved verbatim` markers by copying the named line ranges from `$SRC` at `0832f92`. Confirm the ranges first: `sed -n 31,157p $SRC/buildKit/Layer.mill`. The trait must end where `fixRanges` ends, and line 157 is `Layer`'s own closing brace, so it is not copied. Confirm the other range with `sed -n '/^object ScalaSemanticClasspathMetadata/,/^}/p' $SRC/build.mill`. Delete the marker comments once they are filled.

- [ ] **Step 2: Write recipe §7**

Insert this into `kit/recipes/mill.md`:

````markdown
## 7. The gate's tasks

The harness engine (`kit/harness`, vendored to `.dsh/engine/` by `install.sh`) runs Mill tasks **by name**:
`moduleMap`, `<module>.fixRanges --rangesFile <path>`, `<module>.fixStrict`, `<module>.compile`, `preCommit`,
`prePush`, `scalaSemanticWriteClasspath`. Copy `kit/recipes/mill/Gate.mill` to `buildKit/Gate.mill`, mix `GateLayer`
into every module that scalafix checks, and add these root tasks to `build.mill`. The four lists are the project's
decisions — a module deliberately exempt from scalafix is left out of `scalafixModules`, not hidden in a trait:

```scala
import mill.scalalib.scalafmt.ScalafmtModule
import build.buildKit.{Gate, GateLayer}

private def mainModules: Seq[ScalaModule with ScalafmtModule] = Seq(core)
private def scalafixModules: Seq[GateLayer]                    = Seq(core)
private def testCompileModules: Seq[ScalaModule]               = Seq()
private def prePushTestModules: Seq[TestModule]                = Seq()

/** Fast gate for every commit: format, lint-check, compile. */
def preCommit() = Task.Command {
  Task.traverse(mainModules)(_.reformat())()
  Task.traverse(scalafixModules)(_.fix("--check"))()
  Task.traverse(scalafixModules)(_.fixStrict)()
  Task.traverse(mainModules ++ testCompileModules)(_.compile)()
  ()
}

/** Thorough gate for every push: preCommit plus the tests. */
def prePush() = Task.Command {
  preCommit()
  Task.traverse(prePushTestModules)(_.testForked())()
  ()
}

/** The coverage map the engine reads (`.dsh/contract`'s `coverage` key). */
def moduleMap() = Task.Command {
  println(
    Gate.moduleMapRows(this, BuildPaths.repoRoot, _.isInstanceOf[ScalafmtModule], mainModules, scalafixModules, testCompileModules)
      .mkString("\n")
  )
}

/** `.scala-semantic/classpath-mill.json`, which the ScalaSemantic server discovers to start its presentation compiler. */
def scalaSemanticWriteClasspath() = Task.Command {
  val modules = Task.traverse(mainModules) { m =>
    Task.Anon {
      Gate.ClasspathMetadata.Module(
        id = m.moduleSegments.parts.mkString("."),
        baseDir = m.moduleDir,
        scalaVersion = m.scalaVersion(),
        classpath = m.compile().classes.path +: m.compileClasspath().map(_.path).toSeq
      )
    }
  }()
  val root    = BuildPaths.repoRoot
  val out     = Gate.ClasspathMetadata.metadataPath(root)
  val changed = Gate.ClasspathMetadata.writeIfChanged(out, Gate.ClasspathMetadata.render(root, modules))
  Task.log.info(s"${if (changed) "Wrote" else "Up to date"} ScalaSemantic classpath metadata: $out (${modules.size} modules)")
}
```

`core` is the example's module; `object core extends ScalaModule with ScalafmtModule with GateLayer { … }`. Checked by
`kit/harness/tests/smoke-second-project.sh`, which assembles a project from this section's text.
````

- [ ] **Step 3: Make the installer vendor `Gate.mill`**

In `Setup.scala`, directly after `writeVendored("buildKit/ArchitectureShapeModule.mill", helper)`:

```scala
        writeVendored("buildKit/Gate.mill", readKit("recipes/mill/Gate.mill"))
```

Then compile-check: `cd $T && scala-cli compile Setup.scala --server=false 2>&1 | tail -3`
Expected: no errors.

- [ ] **Step 4: Verify that `Gate.mill` compiles in a scratch assembly**

The full assembly check is Task 5's smoke script. Here, the assertion is that the file compiles against Mill 1.1.8. Build a scratch project with the recipe's §1 `build.mill` head fragment (it defines `BuildPaths`), `buildKit/package.mill` (copy `$SRC/buildKit/package.mill`), `buildKit/Gate.mill`, and one module `core` (`object core extends ScalaModule with ScalafmtModule with GateLayer { def scalaVersion = "3.8.4" }`) with `core/src/A.scala` (`object A`). Add §7's root tasks. Then run:

```bash
./mill --no-server --ticker false resolve _ && ./mill --no-server --ticker false moduleMap
```

Expected: `resolve` lists `moduleMap`, `preCommit`, `prePush`, `scalaSemanticWriteClasspath` and `core`; `moduleMap` prints `core<TAB>core<TAB>fmt,scalafix`.

If Mill refuses the empty `Seq()` in `Task.traverse`, change §7's text and the smoke test to the form that compiles. Ledger the change as `Task 3: Ruling:`.

- [ ] **Step 5: Commit**

```bash
cd $T && git add kit/recipes/mill/Gate.mill kit/recipes/mill.md Setup.scala && git commit -q -m "kit(mill): Gate.mill — the engine's Mill interface — and the recipe's gate tasks; the installer vendors it

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

---

### Task 4: skreeep2 becomes the first consumer

**Files (in `$S`):**
- Delete: `.dsh/{gate.sh,lib.sh,verify-diff.sh,module-map.sh,check-harness.sh,instructions-sync.sh}`, `.dsh/hooks/`, and `.dsh/tests/` **except** `wiring-test.sh` and `committed-tree-test.sh`
- Create: `.dsh/engine/` (by `install.sh`), `buildKit/Gate.mill` (a copy of the template's)
- Modify: `.dsh/hooks.json`, `.dsh/cc-settings.json`, `.dsh/frozen-paths`, `.dsh/README.md`, `.dsh/bootstrap.sh`, `.dsh/tests/wiring-test.sh`, `.dsh/tests/committed-tree-test.sh`, `buildKit/Layer.mill`, `build.mill`, and any `CLAUDE.md`/`AGENTS.md`/`.dsh/profile/cordis.patch.yml` line the residual grep finds

**Interfaces:**
- Consumes: Task 2's `install.sh`; Task 3's `GateLayer` and `Gate`.
- Produces: a skreeep2 whose `.dsh/` holds `engine/` (vendored, stamped), project state, and a project-only `tests/`.

- [ ] **Step 1: Worktree and the before-captures**

```bash
cd /Users/viktorskalinins/IdeaProjects/skreeep2 && git worktree add -b vendor-engine ../skreeep2-vendor-engine master
S=/Users/viktorskalinins/IdeaProjects/skreeep2-vendor-engine; cd $S
./mill -j 1 --ticker false moduleMap > /tmp/mm-before.txt 2>/dev/null; wc -l < /tmp/mm-before.txt
./mill -j 1 --ticker false scalaSemanticWriteClasspath && cp .scala-semantic/classpath-mill.json /tmp/cp-before.json
```

Expected: a non-zero row count, and the classpath file written.

- [ ] **Step 2: Build side: `Gate.mill` in, duplicates out**

- `cp $T/kit/recipes/mill/Gate.mill buildKit/Gate.mill`
- `buildKit/Layer.mill`: `trait Layer extends Common with ScalafixModule` becomes `trait Layer extends Common with GateLayer`. Delete lines 31–156 (now in `GateLayer`). Keep `scalafixIvyDeps` and `scalafixToolClasspath`. Drop the imports that become unused (`CollectionConverters`, `OptionConverters`, `BuildPaths`, if nothing else uses them).
- `build.mill`: import `build.buildKit.Gate`. Replace `moduleMap`'s body with:
  ```scala
  println(Gate.moduleMapRows(this, BuildPaths.repoRoot, _.isInstanceOf[Common], mainModules, scalafixModules, testCompileModules).mkString("\n"))
  ```
  Keep its doc comment, but change its `.dsh/module-map.sh` mention to `.dsh/engine/module-map.sh`. In `scalaSemanticWriteClasspath`, replace `ScalaSemanticClasspathMetadata` with `Gate.ClasspathMetadata`, and delete `object ScalaSemanticClasspathMetadata`.

Run:
```bash
./mill -j 1 --ticker false moduleMap > /tmp/mm-after.txt 2>/dev/null; cmp /tmp/mm-before.txt /tmp/mm-after.txt && echo MM-IDENTICAL
./mill -j 1 --ticker false scalaSemanticWriteClasspath && cmp /tmp/cp-before.json .scala-semantic/classpath-mill.json && echo CP-IDENTICAL
./mill -j 1 preCommit; echo "preCommit exit $?"
```
Expected: `MM-IDENTICAL`, `CP-IDENTICAL`, `preCommit exit 0`.

- [ ] **Step 3: Engine out, vendored engine in**

```bash
cd $S
git rm -q -r .dsh/gate.sh .dsh/lib.sh .dsh/verify-diff.sh .dsh/module-map.sh .dsh/check-harness.sh .dsh/instructions-sync.sh .dsh/hooks
git ls-files .dsh/tests | grep -v -e '^\.dsh/tests/wiring-test\.sh$' -e '^\.dsh/tests/committed-tree-test\.sh$' | xargs git rm -q
sh $T/kit/harness/install.sh $S
```
Expected: `seeded   .dsh/engine (template <sha>)`, and `kept` for every state file, since skreeep2 already has all of them.

- [ ] **Step 4: Rewire**

```bash
sed -i '' 's#/\.dsh/gate\.sh#/.dsh/engine/gate.sh#g' .dsh/hooks.json .dsh/cc-settings.json
grep -c 'engine/gate.sh' .dsh/hooks.json .dsh/cc-settings.json
```
Expected: 6 and 6.

`.dsh/frozen-paths`: delete the rows for `.dsh/gate.sh`, `.dsh/lib.sh`, `.dsh/hooks/**`, `.dsh/check-harness.sh`, `.dsh/instructions-sync.sh` and `.dsh/verify-diff.sh`. Add this in their place (TAB-separated):
```
.dsh/engine/**	the engine is vendored from scala-llm-template/kit/harness; edit it there and re-run install.sh
```

Residual references across the project:
```bash
grep -rnE "$ENGINE_RE" . --include='*.sh' --include='*.json' --include='*.yml' --include='*.md' --include='*.mill' --include='*.scala' --exclude-dir=engine --exclude-dir=out --exclude-dir=node_modules --exclude-dir=docs | grep -v '\.dsh/engine/'
```
Rewrite each hit to `.dsh/engine/…`. That covers `bootstrap.sh`'s call to `check-harness.sh`, `wiring-test.sh`, `committed-tree-test.sh`, `CLAUDE.md`/`AGENTS.md` lines, and `.dsh/profile/cordis.patch.yml`. `docs/` holds historical plans and specs, which are left as written.

Expected after rewriting: the grep prints nothing.

- [ ] **Step 5: Project suites run against the vendored engine**

- `wiring-test.sh`: `repo` stays the project root (it reads `.dsh/hooks.json` and `.dsh/cc-settings.json`). Every gate path it asserts becomes `.dsh/engine/gate.sh`.
- `committed-tree-test.sh`: inside the clone it runs `.dsh/engine/tests/run.sh` and `.dsh/engine/check-harness.sh`.

Run: `sh .dsh/tests/wiring-test.sh | tail -2`
Expected: the wiring suite passes on the committed wiring files. The 13 failures recorded earlier came from the untracked `.claude/settings.json`'s stale entry. If they still appear, they must name only `.claude/settings.json`. The Step 8 human step fixes them. Ledger this.

- [ ] **Step 6: Split the README**

`.dsh/README.md` keeps the project-state sections: the contract, frozen paths, the policies, the instruction tables, the skills, the DSH profile/bootstrap, and the two commands. It gains a first paragraph:

> The engine (gate, hooks, checks, tests) is vendored in `.dsh/engine/` from `scala-llm-template/kit/harness` by `install.sh`, and documented in `.dsh/engine/README.md`. Never edit `.dsh/engine/` here: edit the template, then re-run `sh <scala-llm-template>/kit/harness/install.sh .`.

The engine sections (the subs, the notes table, the blind spots, verify-diff, the rewrite stage, memorisation) move to Task 6's engine README. Here, delete them and leave one link line per moved section.

- [ ] **Step 7: The host check**

Run:
```bash
cd $S && sh .dsh/engine/check-harness.sh > /tmp/ch.log 2>&1; echo "exit $?"; grep -E '^FAIL' /tmp/ch.log; grep -E 'STAMP|vendored' /tmp/ch.log
```
Expected: `exit 0`; no FAIL line other than ones naming `.claude/settings.json` (fixed in Step 8); `ok   vendored engine matches its STAMP (template <sha>)`.

- [ ] **Step 8: Human step, the Claude Code wiring**

Stop and give the human this, verbatim:

```bash
cd /Users/viktorskalinins/IdeaProjects/skreeep2-vendor-engine
diff .claude/settings.json .dsh/cc-settings.json   # review: anything besides hooks you want to keep?
cp .dsh/cc-settings.json .claude/settings.json      # replaces the stale PreToolUse entry too
```

(`.claude/settings.json` is untracked and frozen. `bootstrap.sh` only installs it when absent, and the agent is not permitted to edit it.) After the human confirms, re-run Step 7 and `sh .dsh/tests/wiring-test.sh`.
Expected: `exit 0` for both.

- [ ] **Step 9: The stamp survives a full check (Review Focus 1)**

Run: `sh .dsh/engine/check-harness.sh --full > /tmp/chf.log 2>&1; echo "exit $?"; . .dsh/engine/lib.sh; dsh_engine_stamp_verdict .dsh/engine`
Expected: `exit 0` and `ok`. A `mismatch` means a suite wrote inside the engine. Fix that suite in the template (write to `mktemp -d`), re-vendor, and repeat.

- [ ] **Step 10: The frozen semantics survived**

Use a PreToolUse Write payload against the vendored engine:

```bash
cd $S
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/.dsh/engine/lib.sh","content":"x"}}' "$S" | CLAUDE_PROJECT_DIR=$S sh .dsh/engine/gate.sh tool-policy; echo "write engine: $?"
printf '{"tool_name":"Read","tool_input":{"file_path":"%s/.dsh/engine/lib.sh"}}' "$S" | CLAUDE_PROJECT_DIR=$S sh .dsh/engine/gate.sh semantic-guard; echo "read engine: $?"
```

Expected: `write engine: 2`, with a reason naming `the engine is vendored from scala-llm-template`; `read engine: 0`. If frozen writes are enforced by a sub other than `tool-policy` for the Write tool, use the sub that `.dsh/hooks.json` wires for Write (check with `grep -n '"write' .dsh/hooks.json`). Ledger which one.

- [ ] **Step 11: Live session smoke**

In a Claude Code session started in `$S`, run by the human or by the controller if it can start one there:
- ask to Read a `.scala` source; expect it denied by the semantic guard;
- ask to Write `.dsh/engine/gate.sh`; expect it denied by the freeze;
- edit a `.scala` file and end the turn; expect the Stop gate to run the checks.

Record all three in the task report.

- [ ] **Step 12: Commit (path-limited)**

```bash
cd $S && git add .dsh buildKit/Gate.mill buildKit/Layer.mill build.mill $(git diff --name-only -- CLAUDE.md AGENTS.md) && git status --short | grep -v '^??' 
git commit -q -m "dsh: vendor engine $(sed -n 's/^template=//p' .dsh/engine/STAMP | cut -c1-7); the project keeps its state; buildKit consumes the kit's Gate.mill

Engine moved to scala-llm-template/kit/harness (source) and vendored to .dsh/engine/ by install.sh.
Moved: gate.sh lib.sh verify-diff.sh module-map.sh check-harness.sh instructions-sync.sh hooks/ tests/ (engine suites).
Kept here: contract frozen-paths policy/ instructions/ skills/ profile/ bootstrap.sh dsh.sh hooks.json cc-settings.json,
and tests/wiring-test.sh + tests/committed-tree-test.sh (project suites).

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

Expected: the staged list does not contain `Wiring.scala`.

---

### Task 5: Setup's harness step, and the second-project smoke

**Files:**
- Modify: `$T/Setup.scala`. Add an `InstallHarness` step, and make `InstallKit.findKitRoot` non-private so the new step can reuse it.
- Create: `$T/kit/harness/tests/smoke-second-project.sh`. It is **not** named `*-test.sh`, because it needs real Mill and network and must not join check-harness's discovery.

**Interfaces:**
- Consumes: Task 2's `install.sh`; Task 3's `Gate.mill` and recipe §7.
- Produces: `install-harness` in Setup's JSON step list; a re-runnable smoke that exits 0 when every assertion holds.

- [ ] **Step 1: The Setup step**

```scala
  /** The harness engine (spec 2026-09-26): `kit/harness/install.sh` vendors it into `<target>/.dsh/engine/` and seeds
    * the project's gate state. Mill only — the engine's checks run Mill tasks by name — so any other build tool is a
    * named skip, never a silent one. The step's status is install.sh's exit status.
    */
  private object InstallHarness extends SetupStep:
    val id = "install-harness"

    def run(ctx: SetupContext): StepResult =
      if ctx.answers.getOrElse("kit", "no").toLowerCase != "yes" then StepResult(id, "skipped", "kit not selected")
      else if ctx.answers.getOrElse("build-tool", "mill").toLowerCase != "mill" then
        StepResult(id, "skipped", "harness engine supports Mill builds only")
      else
        InstallKit.findKitRoot() match
          case None => StepResult(id, "failed", "kit sources not found: run Setup.scala from a scala-llm-template checkout")
          case Some(kit) =>
            val r = os
              .proc("sh", (kit / "harness" / "install.sh").toString, ctx.targetDir.toString)
              .call(check = false, mergeErrIntoOut = true)
            val out = r.out.text()
            Console.err.print(out)
            if r.exitCode == 0 then
              StepResult(id, "completed", "vendored the harness engine into .dsh/engine", List((ctx.targetDir / ".dsh" / "engine").toString))
            else
              StepResult(id, "failed", s"install.sh exited ${r.exitCode}: ${out.linesIterator.toList.lastOption.getOrElse("")}")
```

Put it in the step list. `install.sh` requires a git repository, so place it after whichever step initialises git in the target. Find that step with `grep -n 'git.*init\|"init"' Setup.scala`. If no step initialises git before `FormatProject`, place `InstallHarness` directly after `InstallKit` and ledger that a fresh Setup target must be a git repository first. The smoke initialises one.

Run: `cd $T && scala-cli compile Setup.scala --server=false 2>&1 | tail -3`
Expected: no errors.

- [ ] **Step 2: Write the smoke**

`smoke-second-project.sh` uses the same `is` helper as `install-test.sh`. Its sequence:

1. `w=$(mktemp -d)`; `git init -q`.
2. Assemble a scratch Mill project from the recipe's own text:
   - extract the §1 head fragment and the §7 block from `kit/recipes/mill.md` with `awk` between their fences (the §1 fence is the first `scala` block under `## 1.`; §7's is the one under `## 7.`);
   - copy `kit/recipes/mill/Gate.mill` and a `buildKit/package.mill` anchor;
   - write `.mill-version` = `1.1.8`, a `./mill` wrapper (copy from `$SRC/mill`), and `object core extends ScalaModule with ScalafmtModule with GateLayer { def scalaVersion = "3.8.4" }` with `core/src/A.scala` (`package a\nobject A { val x: Int = 1 }`);
   - add an unmapped `scripts/Tool.scala` (`object Tool`);
   - commit.
3. `sh $engine/install.sh "$w"` returns exit 0.
4. `./mill --ticker false moduleMap` prints exactly `core\tcore\tfmt,scalafix`. There is no `tests` capability, because `core` has no test module.
5. `./mill core.compile core.semanticDbData`; then run the `health` payload. `.dsh/.state/health` must contain `healthy=1` (requires the scalasemantic-mcp launcher; skip this assertion **with a printed SKIP line** if `~/.local/bin/scalasemantic-mcp` is absent).
6. semantic-guard with a Read of `core/src/A.scala` exits 2.
7. Set `SCALASEMANTIC_MCP_LAUNCHER=/nonexistent` and re-run health, which gives `healthy=0`. The same Read then exits 0, and its output contains `stands down`.
8. Turn-end: run the `baseline` payload, append `val y: Int = 2` inside `object A`, then run the Stop payload. It exits 0, and its output does not match `test` in a claim sense: `grep -Ei 'tests? (pass|ran|run)'` finds nothing.
9. Turn-end with only `scripts/Tool.scala` changed (reset, then edit it) exits 0, and `./mill` is not run for it. Assert through a PATH-first wrapper that logs Mill calls, in the same way as the `tests/bin/mill` stub's log. This is the unmapped-path ruling.
10. `./mill -j 1 preCommit` exits 0.
11. An sbt scratch repository (`build.sbt`, `src/A.scala`, git init, `install.sh`): the health output contains `gate engine supports Mill builds only; found: build.sbt`, and a dirty Stop exits 0 with the same note.
12. Setup end to end: `scala-cli run $T/Setup.scala --server=false -- --agent --answers '{"kit":"yes","build-tool":"mill"}' <fresh dir>`. The JSON on stdout has a step `install-harness` with `"status":"completed"`, and `<fresh dir>/.dsh/engine/STAMP` exists. Run it after the fresh directory is git-initialised if Step 1 placed the step before any git initialisation.

Every Mill call uses `--no-server --ticker false`, with `COURSIER_CACHE` left as default on the host.

- [ ] **Step 3: Run it**

Run: `sh $T/kit/harness/tests/smoke-second-project.sh 2>&1 | tail -25`
Expected: `N passed, 0 failed`. Any SKIP line is named in the task report.

Where the smoke disagrees with this plan, work out whether the recipe text or the engine is wrong, fix it in its own file, and ledger a ruling.

- [ ] **Step 4: Commit**

```bash
cd $T && git add Setup.scala kit/harness/tests/smoke-second-project.sh && git commit -q -m "kit(harness): Setup's install-harness step, and a second-project smoke assembled from the recipe's own text

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

---

### Task 6: Documentation

**Files:**
- Create: `$T/kit/harness/README.md`
- Modify: `$T/kit/apply.md`
- Modify (guidelines repo, on master): `docs/2026-09-19-reengineering-kit-plan-c-harness.md` (a superseded banner), `docs/2026-09-19-reengineering-kit-design.md` (§L4 amendment), and `wiki/reengineering/verification-and-the-gate.md` plus `wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md` **through the karpathy-llm-wiki skill**
- Re-vendor: `$S` (the README is an engine file, so the STAMP changes)

**Interfaces:**
- Consumes: everything above.
- Produces: the record (R-12).

- [ ] **Step 1: The engine README.** Move the engine sections of skreeep2's pre-Task-4 `.dsh/README.md` (read it with `git -C $SRC show 0832f92:.dsh/README.md`) into `kit/harness/README.md` verbatim: the subs, the notes table (18 rows), the blind spots, verify-diff, the rewrite stage, memorisation. Rewrite `.dsh/<engine file>` paths to `.dsh/engine/…`. Then add these sections:
  - **Layout**: the Engine layout rule.
  - **Install and update**: the `install.sh` usage and exit codes, the seed list, STAMP's three fields.
  - **Drift**: the group G table.
  - **The contract**: the keys, including the optional `holdout`, `fastTests` and `turnEndTests`.
  - **The Mill interface**: the seven task names, with a pointer to recipe §7.
  - **Non-Mill projects**: the positive-evidence rule.
  - Two new rows for the notes table: `vendored engine does not match its stamp` and `gate engine supports Mill builds only`.
  - A blind-spot row: `a .scala path in no module is skipped at turn-end without a note`.

- [ ] **Step 2: `kit/apply.md`.** Add a harness step after the kit install step. It gives the `install.sh` command, says that the `.claude/settings.json` wiring is copied from `.dsh/cc-settings.json` by the human, and says to add recipe §7's root tasks. Remove the "Not in this document: … the harness (L4 …; Plan C)" clause and point to `kit/harness/README.md`.

- [ ] **Step 3: Verify, commit, re-vendor**

```bash
cd $T && sh kit/harness/tests/run.sh 2>&1 | tail -1 && git add kit/harness/README.md kit/apply.md && git commit -q -m "kit(harness): the engine's README, and apply.md's harness step

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
sh kit/harness/install.sh $S && cd $S && sh .dsh/engine/check-harness.sh | grep -E 'STAMP|^FAIL' ; git add .dsh/engine && git commit -q -m "dsh: vendor engine $(sed -n 's/^template=//p' .dsh/engine/STAMP | cut -c1-7) (engine README)

Claude-Session: https://claude.ai/code/session_01TEcqcxKmBFZQupRykQoDMX"
```

Expected: run.sh reports `0 failed`; the check shows `ok   vendored engine matches its STAMP` and no FAIL.

- [ ] **Step 4: Guidelines docs**

- The old Plan C gets, as its first line under the title: `> **Superseded (2026-09-26)** by docs/superpowers/specs/2026-09-26-harness-engine-vendoring-design.md and scala-llm-template docs/superpowers/plans/2026-09-26-harness-engine-vendoring.md. The engine's home is scala-llm-template/kit/harness, vendored per project; not the DSH profile.`
- The design's §L4 gets an **Amended 2026-09-26** paragraph saying the same, with one sentence of why: Claude Code never passes through the profile, and the profile is generated from the repository.
- The wiki: use the karpathy-llm-wiki skill to update `verification-and-the-gate.md` (where the gate lives now) and the roadmap (a Reengineering Kit status line). Run the skill's `check_evidence.py`.

Commit on guidelines master, path-limited.

---

## Self-review notes

- **Spec coverage:**
  - §1 layout → Tasks 1 and 4; split rule → Task 4 Steps 3–6; frozen `.dsh/engine/**` → Task 2 seed and Task 4 Step 4; dropped items → nothing to build.
  - §2 install/STAMP/seeds → Task 2 Steps 1–6; drift table → Task 2 Step 9; health note → Task 2 Step 8; engine workflow → Task 6 Step 3; tests split → Task 1 Step 1 and Task 4 Step 5.
  - §3 Gate.mill and recipe → Task 3; skreeep2 consumes → Task 4 Step 2; non-Mill → Task 2 Steps 7–8 (ruled to positive evidence).
  - §4 steps 1–6 → Tasks 1–6.
  - Invariants → Global Constraints.
- **Placeholder scan:** the two `── moved verbatim` markers in Task 3 Step 1 are copy instructions with exact source ranges and a confirming command, not content to invent.
- **Type consistency:** `GateLayer`, `Gate.moduleMapRows(root, repoRoot, isFormattable, main, scalafix, testCompile)` and `Gate.ClasspathMetadata` have the same names in Tasks 3, 4 and 5. The `dsh_engine_*`, `dsh_is_vendored_engine` and `dsh_non_mill_build` names match across Task 2's tests, `lib.sh`, `health.sh` and check-harness.
