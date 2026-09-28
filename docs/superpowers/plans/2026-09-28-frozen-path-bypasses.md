# Frozen-Path Bypasses and Turn-End Test Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a write to a frozen path fail the turn whatever route performed it, deny interpreter/inline-shell commands that name a frozen path, and give `turnEndTests` their own time cap.

**Architecture:** A post-hoc check runs first at turn-end: every path this session changed (git's full porcelain list, deletions and new files included, filtered by the existing session baseline) that matches a frozen pattern blocks; git-ignored frozen files get a SessionStart hash record that turn-end re-hashes. `tool-policy` gains a text rule for `python|perl|ruby|node`, `sh|bash|zsh|dash -c` and writing `awk`. `turnEndTests` runs under `dsh_bounded_probe` inside the Stop budget.

**Tech Stack:** POSIX sh (dash-clean), the engine's fixture runner, git porcelain `-z`.

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-09-28-frozen-path-bypasses-design.md`

## Global Constraints

- Engine is edited in `kit/harness/` only; vendored later. POSIX sh, no `local`, no arrays, no `set -e` in hooks; `dash -n` clean; `sh tests/run.sh` and `dash tests/run.sh` all pass; every `tests/*-test.sh` passes (dash health-test's 6 known length-cap failures excepted — report if the count changes).
- The gate never silently passes; frozen semantics only get stricter; reads stay allowed through the Read tool.
- Block headlines verbatim: `frozen path changed this turn: <path>`, `frozen path removed this turn: <path>`, `frozen record missing: <path>`; note `frozen ignored paths not compared` (for an `incomplete:` record); note `turnEndTests: <m> did not finish within <N> s — not verified`.
- New frozen seed row, TAB-separated: `.dsh/.state/frozen/**	the frozen-path hash record is the human's record of the frozen files at session start`.
- Knobs: `DSH_TESTS_CAP` (default 300), existing `DSH_STOP_BUDGET` (540); both through `dsh_decimal`.
- Commits end with `Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU`; never `Co-Authored-By`; never `--no-verify`.

## Review Focus

1. A frozen file the gate itself rewrites during a normal turn (`.dsh/.state/receipts`, `.dsh/.state/modules.tsv`, `.dsh/.state/holdout.log`, this session's own records) must not trigger the post-hoc block — pinned in Task 2 (`frozen-ignored-gate-writes-not-blocked`).
2. A frozen file already dirty at SessionStart that the agent does not touch must not block every turn — pinned in Task 1 (`frozen-predirty-untouched-passes`).
3. A rename of a frozen file (`git mv` via an ungated route) reports both names — the source counts as removed — pinned in Task 1 (`frozen-renamed-blocks`).
4. The interpreter rule must not deny commands that merely mention a word equal to a frozen file's basename in unrelated context when the frozen row is an exact path — match on path spellings (root-relative, `./`-prefixed, absolute), not bare basenames — pinned in Task 3 (`interp-basename-only-allowed`).
5. A `turnEndTests` run killed by the cap must leave no orphan test JVM — pinned in Task 4 via `_dsh_kill_tree` and a fixture asserting the stub's child sleep is gone.

---

### Task 1: Post-hoc check for tracked/untracked frozen paths

**Files:** `kit/harness/lib.sh` (new `dsh_changed_paths`), `kit/harness/hooks/turn-end.sh` (new stage right after the touched-files loop ~line 333, before diff-scoped verification), fixtures, `tests/lib-test.sh`

**Interfaces:**
- Produces: `dsh_changed_paths <root> <out>` — every path git reports as changed vs HEAD plus untracked (porcelain `-z -uall` + `git diff --name-only -z HEAD`), ALL extensions, deleted paths included, BOTH names of a rename; exit codes as `dsh_touched_files` (0 / 1 not a work tree / 2 read failed). Reuse `dsh_touched_files`' parsing — factor the shared part rather than copy it (read lines ~430–520 first).

- [ ] **Step 1: RED fixtures** (model on an existing `turn-end-*` case with `git_init`/`post_git`; frozen rows in the case's `root/.dsh/frozen-paths`):
  - `frozen-edited-by-interpreter-blocks`: `post_git` rewrites a committed frozen file (`printf x >> engine/details/A.scala`) → exit 2, grep `frozen path changed this turn: engine/details/A.scala`.
  - `frozen-deleted-blocks`: `post_git` removes a committed frozen file → exit 2, grep `frozen path removed this turn:`.
  - `frozen-new-file-in-frozen-dir-blocks`: `post_git` creates `engine/details/New.scala` under a `engine/details/**` row → exit 2, grep `frozen path changed this turn: engine/details/New.scala`.
  - `frozen-renamed-blocks`: `post_git` `git mv` a frozen file → exit 2, grep both paths (source as removed).
  - `frozen-predirty-untouched-passes`: the frozen file is dirty at SessionStart (baseline case pattern: an existing `baseline-*` case shows how a fixture seeds a session baseline) and unchanged at turn-end → exit 0, no `frozen path` text.
  - `frozen-predirty-changed-blocks`: same, changed further → exit 2.
  - `frozen-none-configured-runs-nothing`: no frozen rows, a non-Scala file changed → exit 0, no `frozen path` text.
  Run `sh tests/run.sh` → these FAIL.
- [ ] **Step 2: Implement** `dsh_changed_paths`; in turn-end, after the touched loop: for each changed path, skip if `baseline_state=session` and `dsh_baseline_hash` equals the current hash (`dsh_file_hash`, `-` for a deleted file); if `dsh_frozen_reason "<path>" "$root"` is non-empty → `blocked+1`, `section blocking "frozen path <changed|removed> this turn: <path>" "<reason>\nYou cannot restore it — writing a frozen path is what the freeze denies. Stop and ask the human: git diff -- <path> shows what changed; the human restores or keeps it."`. A `not a work tree` / read failure follows the existing touched-files handling (fail closed).
- [ ] **Step 3: GREEN** — all suites, both shells; lib-test rows for `dsh_changed_paths` (deleted, rename, untracked, non-ASCII name).
- [ ] **Step 4: Commit** `kit(harness): a frozen path changed this session blocks at turn-end, whatever route wrote it`.

### Task 2: Git-ignored frozen files — SessionStart hash record

**Files:** `kit/harness/hooks/baseline.sh`, `kit/harness/hooks/turn-end.sh` (same stage as Task 1), `kit/harness/lib.sh`, `kit/harness/seed/frozen-paths`, `kit/harness/lib.sh` `dsh_kernel_checks`-style installation rule in `dsh_verify_checks` (or a new `dsh_frozen_record_checks` wired into `check-harness.sh`), fixtures

**Interfaces:**
- Produces: `dsh_frozen_record_file <sid>` → `$(state_dir)/frozen/<key>.tsv`; `dsh_frozen_ignored_files <root>` → the existing git-ignored files matching a frozen `exact`/`prefix` entry (use `dsh_frozen_paths` + `git check-ignore --stdin -z`), minus the gate's own writes: `.dsh/.state/receipts`, `.dsh/.state/modules.tsv`, `.dsh/.state/holdout.log`, `.dsh/.state/unverified.log`, anything under `.dsh/.state/frozen/`, `.dsh/.state/contracts/`, `.dsh/.state/baseline-*`, `.dsh/.state/turn-end-*` (list them in one place; read the gate for any other state file it writes during a turn and add it with a comment).

- [ ] **Step 1: RED fixtures**:
  - `frozen-ignored-changed-blocks`: `root/.gitignore` ignores `local/`; frozen row `local/**`; a pre_gate SessionStart (`baseline` sub) records `local/k.txt`; `post_git` rewrites it → exit 2, grep `frozen path changed this turn: local/k.txt`.
  - `frozen-ignored-removed-blocks`: removed → exit 2, `frozen path removed this turn`.
  - `frozen-record-missing-blocks`: the record deleted → exit 2, grep `frozen record missing:`.
  - `frozen-record-incomplete-notes`: record header `incomplete: …` → exit 0, grep `frozen ignored paths not compared`.
  - `frozen-ignored-gate-writes-not-blocked`: frozen `.dsh/.state/receipts` changed by the gate's own holdout receipt path (or directly in post_git to simulate) → exit 0 (Review Focus 1).
  - `baseline-records-frozen-ignored`: SessionStart writes the record with the expected row; a second SessionStart keeps it.
  RED.
- [ ] **Step 2: Implement** — baseline.sh writes the record right after the contract snapshot, before the file-baseline early exits (header `# DSH frozen-ignored <sid> <iso>`, or `incomplete: <reason>`, temp + mv; never blocks). turn-end re-hashes each recorded path (changed/removed → block as Task 1), record absent while frozen rows exist → block `frozen record missing: <path>`, `incomplete:` → `section note`/`vk_note`-style note that reaches the agent on every exit (reuse the vericoding stage's note channel or add `fz_note` flushed the same way — read how `vk_note` is flushed in `block()` and on allow).
- [ ] **Step 3: Seed + installation rule** — `seed/frozen-paths` row (Global Constraints); `check-harness`: when any frozen rows exist, `.dsh/.state/frozen/x.tsv` must resolve frozen (FAIL `the frozen-path hash records (.dsh/.state/frozen/**) are not frozen — add the row to .dsh/frozen-paths`); lib-test rows.
- [ ] **Step 4: GREEN** + commit `kit(harness): git-ignored frozen files are hashed at SessionStart and checked at turn-end`.

### Task 3: Interpreter text rule in `tool-policy`

**Files:** `kit/harness/hooks/tool-policy.sh`, fixtures

- [ ] **Step 1: RED fixtures** (`tool-policy` sub, Bash payloads; frozen row `engine/details/**` and an exact `.dsh/policy/kernels.tsv` row):
  - denied: `python3 -c "open('engine/details/A.scala','w').write('x')"`; `python3 - <<'EOF'\nopen('engine/details/A.scala','w')\nEOF`; `perl -e 'open F,">engine/details/A.scala"'`; `node -e "require('fs').writeFileSync('engine/details/A.scala','x')"`; `ruby -e "File.write('engine/details/A.scala','x')"`; `sh -c 'echo x > engine/details/A.scala'`; `bash -c "rm engine/details/A.scala"`; `awk '{print > "engine/details/A.scala"}' in.txt`; `python3 -c "open('./engine/details/A.scala','w')"` (dot spelling); `python3 -c "open('<SCRATCH_ROOT>/engine/details/A.scala','w')"` (absolute).
  - allowed: `python3 -c "print(1)"`; `python3 tools/gen.py` (no frozen path in text); `sh -c 'echo hi'`; `awk '{print $1}' engine/other/B.scala`; `python3 -c "print('kernels.tsv')"` when only `.dsh/policy/kernels.tsv` is frozen (`interp-basename-only-allowed`, Review Focus 4).
  RED.
- [ ] **Step 2: Implement** — for each segment whose command word is `python|python2|python3|perl|ruby|node` (any args) or `sh|bash|zsh|dash` with a `-c` among its words, or `awk` whose text contains `print >`, `printf >` or `system(`: scan the WHOLE command text (payload `tool_input.command`) for every frozen entry's spellings — root-relative path, `./`-prefixed, absolute through the gate root (both spellings, like `dsh_repo_relpath`), and for `prefix` entries the directory with a trailing `/`. First hit → deny with the freeze's reason + "an interpreter can write where the shell rules cannot see — read with the Read tool, and ask the human to change a frozen file". Reuse `command_position_words` and `dsh_frozen_paths`.
- [ ] **Step 3: GREEN** + commit `kit(harness): tool-policy denies interpreter and inline-shell commands that name a frozen path`.

### Task 4: `turnEndTests` time cap

**Files:** `kit/harness/hooks/turn-end.sh` (loop ~737–770), `kit/harness/tests/bin/mill` or the feedback stub path, fixtures

- [ ] **Step 1: RED fixtures** — `turnendtests-cap-notes`: contract `turnEndTests` runs a stub that sleeps past `DSH_TESTS_CAP=2` and spawns a child `sleep` → exit 0, grep `turnEndTests: core did not finish within 2 s — not verified`, post_gate asserts no leftover child (`pgrep -f <marker>` empty); `turnendtests-budget-skips-next`: two modules, `DSH_STOP_BUDGET` small → second module note `not started — the Stop hook's budget`.
- [ ] **Step 2: Implement** — wrap the `feedback.sh … sh -c "$te_cmd"` call in `dsh_bounded_probe` with cap `min(dsh_decimal DSH_TESTS_CAP 300, DSH_STOP_BUDGET − elapsed)` (the stage's existing `te_start` elapsed math); on timeout → note, no block, continue; `left ≤ 10` → note and skip remaining modules.
- [ ] **Step 3: GREEN** + commit `kit(harness): turnEndTests run inside the Stop budget with their own cap`.

### Task 5: Docs, and skreeep2

- [ ] **Step 1:** Engine README: a "Frozen paths: what is caught where" table (text rules, interpreter rule, post-hoc check, the documented blind spot), the new notes/blocks in the notes table, the `DSH_TESTS_CAP` knob. `kit/apply.md`: re-vendored projects add the `.dsh/.state/frozen/**` row by hand. Commit.
- [ ] **Step 2 (skreeep2, after the template branch is merged):** re-vendor (`install.sh`), add the frozen row, `check-harness` 0 FAIL, `preCommit` green; commit. Live check (human): in a gated session, ask the agent to change a frozen file via `python3 -c` → denied by tool-policy; and via a script file (`python3 tools/x.py` whose text names no frozen path) → turn-end blocks `frozen path changed this turn`.

## Self-review notes

- Spec §1.1 → Task 1; §1.2 → Task 2; §1.3 → Task 1/2 fixtures; §2 → Task 3; §3 → Task 4; §4 → fixtures per task + Task 5.
