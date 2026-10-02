# Structural Holdout Seal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The agent's shell can never reach the sealed holdout suite: its commands run in Claude Code's OS sandbox that cannot read the holdout, and the gate never leaves an unsandboxed Mill server the agent could use.

**Architecture:** Every Mill process the engine starts goes through one wrapper, `kit/harness/mill-gate.sh`, which runs the project's Mill with `--no-daemon` in the agent's output directory (`MILL_OUTPUT_DIR`, default `out-agent`). Contract commands are rewritten to use the wrapper. The seed settings carry the sandbox block; `check-harness` verifies it against the sealed rows; `health` says when a session's seal is text-only.

**Tech Stack:** POSIX sh (must pass under `sh` and `dash`), Mill 1.1.8, Claude Code sandbox settings (2.1.287), jq or python3 (optional, as the engine already uses them), the fixture runner `kit/harness/tests/run.sh`.

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-02-structural-holdout-seal-design.md` (commit b7724ed in scala-coding-guidelines). Read §3 (measured facts) and §4 (design) before any task.

## Global Constraints

- POSIX sh only: no arrays, no `local`, no `set -e`; `sh -n` and `dash -n` clean; every suite passes under `sh` and `dash`.
- The agent's output directory: contract key `agentOutputDir`, default `out-agent`; valid only if relative, matching `^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$` and containing no `..` segment; anything else → the default (and check-harness FAILs).
- The wrapper passes `--no-daemon` as Mill's FIRST argument and exports `MILL_OUTPUT_DIR=<agent dir>`; it never starts a Mill server.
- Settings keys, exact: `sandbox.enabled: true`, `sandbox.allowUnsandboxedCommands: false`, `sandbox.failIfUnavailable: true`, `sandbox.network.allowLocalBinding: true`, `sandbox.filesystem.allowWrite` ⊇ `["~/.cache/mill", "~/.cache/coursier", "~/Library/Caches/Coursier"]`, `sandbox.filesystem.denyRead` ⊇ `["./out/mill-daemon", "./<agent dir>/<holdout target>", "./<each sealed row path>"]`, `env.MILL_OUTPUT_DIR: "<agent dir>"`.
- The sandbox is REQUIRED only when the contract has a `holdout =` line; otherwise every new check reports a note, never a FAIL, and health prints nothing new.
- Engine files stay git mode 100755 where executable (`mill-gate.sh` must be 100755).
- Commits: message ends with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`; never a `Co-Authored-By` line. Stage explicit paths only.
- Fixtures must be `git add`ed before `lib-test.sh` runs (its fixture-shape check reads tracked files).

## Rulings against the spec

- Spec §4.1 says `out-agent/` is "added to the seed .gitignore lines install.sh maintains": install.sh maintains no
  .gitignore lines (it only warns about vendored files a rule would drop). Ruling: check-harness notes an unignored agent
  directory with the exact line to add (Task 3 row 9), and the recipe tells the human (Task 5). Cost if wrong: one
  manual line per project.

## Review Focus

1. The engine directory path contains a space or a single quote → a rewritten contract command still runs the wrapper (Task 2, lib-test rows).
2. A contract command with leading whitespace or a leading `NAME=value` → the assignment stays in front and `./mill` is still replaced (Task 2).
3. Neither jq nor python3 on PATH → check-harness reports a FAIL row naming that, and does not crash or print a raw error (Task 3).
4. `agentOutputDir` absolute, with `..`, or with a space → the wrapper uses `out-agent`, check-harness FAILs naming the bad value (Tasks 1 and 3).
5. A project with no `holdout =` line → no new FAIL in check-harness, no new health line (Tasks 3 and 4).

---

### Task 1: The Mill wrapper, and every direct Mill call through it

**Files:**
- Create: `kit/harness/mill-gate.sh` (mode 100755)
- Modify: `kit/harness/lib.sh` (`resolve_mill` at ~line 234; add `resolve_real_mill`, `dsh_agent_output_dir`)
- Modify: `kit/harness/module-map.sh:90` (literal `./mill --ticker false moduleMap`)
- Modify: `kit/harness/hooks/turn-end.sh:~1371` (vericoding call: drop `--no-server`)
- Modify: `kit/harness/tests/bin/mill` (optional env log)
- Modify: every `kit/harness/tests/cases/*/expect.loggrep` and `post_gate` whose expectations differ only by the new `--no-daemon`; `kit/harness/tests/module-map-test.sh` expectations likewise
- Test: `kit/harness/tests/lib-test.sh` (rows), new fixture cases under `kit/harness/tests/cases/`

**Interfaces:**
- Produces: `resolve_real_mill <root>` → prints `./mill` or the PATH `mill` (exactly today's `resolve_mill` logic), exit 1 when neither.
- Produces: `resolve_mill <root>` → prints the absolute path of `<engine>/mill-gate.sh` when `resolve_real_mill` succeeds, exit 1 otherwise. `<engine>` is `$here` (every hook and module-map.sh sets it to the engine directory before sourcing lib.sh), falling back to `$(gate_root)/.dsh/engine`. Callers keep using `"$mill" args…`.
- Produces: `dsh_agent_output_dir [root]` → prints the agent directory per Global Constraints (contract `agentOutputDir`, validated, default `out-agent`); exit 0 always; exit status 3 additionally signals "the contract value was invalid, the default was used" (print the default either way).

- [ ] **Step 1: Write failing lib-test rows**

Add to `kit/harness/tests/lib-test.sh`, following the `hc()` pattern there (a `/bin/sh -c '. "$1/lib.sh"; …'` subshell per call):

```sh
aod() { /bin/sh -c '. "$1/lib.sh"; dsh_agent_output_dir "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
aodroot=$(mktemp -d); mkdir -p "$aodroot/.dsh"
: > "$aodroot/.dsh/contract"
is "agent dir: default when the contract has no key" "out-agent
rc=0" "$(aod "$aodroot")"
printf 'agentOutputDir = build-agent\n' > "$aodroot/.dsh/contract"
is "agent dir: the contract key" "build-agent
rc=0" "$(aod "$aodroot")"
for bad in /abs/out '../out' 'out dir' 'a/../b' ''; do
  printf 'agentOutputDir = %s\n' "$bad" > "$aodroot/.dsh/contract"
  is "agent dir: invalid [$bad] falls back" "out-agent
rc=3" "$(aod "$aodroot")"
done
is "mill-gate.sh is executable" "yes" "$([ -x "$engine/mill-gate.sh" ] && echo yes || echo no)"
```

(For `''`: a key with an empty value counts as invalid → rc=3.)

- [ ] **Step 2: Write failing fixture cases**

`kit/harness/tests/bin/mill`: after the existing `printf 'mill %s\n' "$*" >> "${MILL_STUB_LOG:-/dev/null}"` line add

```sh
# MILL_STUB_ENV_LOG names a file that records the MILL_OUTPUT_DIR each call saw (`<unset>` when unset): how a
# case asserts the gate's wrapper ran Mill in the agent's output directory.
if [ -n "${MILL_STUB_ENV_LOG:-}" ]; then printf 'MILL_OUTPUT_DIR=%s\n' "${MILL_OUTPUT_DIR-<unset>}" >> "$MILL_STUB_ENV_LOG"; fi
```

Create `kit/harness/tests/cases/turn-end-mill-gate-no-daemon/` by copying `turn-end-untouched-dirt-ok/` (it has `git_init`, a module map row `engine/details	engine.details	fmt,scalafix`, a root `mill` stub), then:
- delete its `root/mill` (the PATH stub `tests/bin/mill` must answer, it logs arguments);
- `post_git`: `printf '\n// touched\n' >> engine/details/src/A.scala`;
- `env`: `MILL_STUB_ENV_LOG=SCRATCH_ROOT/env.log`;
- `expect.code`: `0`;
- `expect.loggrep`: `mill --no-daemon --ticker false --color false engine.details.compile`;
- `post_gate`:
```sh
#!/bin/sh
# Every Mill call went through the wrapper: the agent's directory, never a server.
[ -s env.log ] || { echo "FAIL: no env log"; exit 1; }
if grep -v '^MILL_OUTPUT_DIR=out-agent$' env.log; then echo "FAIL: a call outside out-agent"; exit 1; fi
if grep -v -- '--no-daemon' "$MILL_STUB_LOG"; then echo "FAIL: a call without --no-daemon"; exit 1; fi
echo "post_gate: all calls through the wrapper"
```
(Check `run.sh`: it exports `MILL_STUB_LOG` to the case; if `post_gate` does not see it, read `$SCRATCH_ROOT/mill.log` instead — that is the file the runner sets.)

Create `turn-end-mill-gate-contract-dir/` the same way with `root/.dsh/contract` holding `agentOutputDir = build-agent` and the post_gate expecting `MILL_OUTPUT_DIR=build-agent`.

Create `post-edit-mill-gate-no-daemon/` by copying an existing green post-edit case that compiles a module (`ls kit/harness/tests/cases | grep '^post-edit'`; pick the one whose `expect.loggrep` names a `.compile`), add the same `env` and `post_gate`.

- [ ] **Step 3: Run to verify they fail**

Run: `cd kit/harness/tests && sh lib-test.sh 2>&1 | grep -E 'agent dir|mill-gate'; RUN_CASES='*mill-gate*' sh run.sh 2>&1 | tail -4`
Expected: the lib-test rows FAIL (`dsh_agent_output_dir: not found`, `mill-gate.sh is executable: wanted [yes], got [no]`); 3 cases FAIL (no `--no-daemon` in the log).

- [ ] **Step 4: Implement**

`kit/harness/mill-gate.sh`:

```sh
#!/bin/sh
# mill-gate.sh <mill args…>: the ONE way the engine starts Mill (spec 2026-10-02 structural holdout seal §4.2).
# It runs the project's Mill (`resolve_real_mill`: ./mill, else mill on PATH) with `--no-daemon` FIRST and
# MILL_OUTPUT_DIR set to the agent's output directory (`dsh_agent_output_dir`, default out-agent). Hooks run
# outside the agent's sandbox, so a Mill server they left behind would run with full access — and a sandboxed
# agent client that found it ran the sealed holdout suite (measured: `+ the holdout suite runs under the gate`).
# `--no-daemon` leaves no server; the shared directory keeps one compile cache with the agent's own builds.
set -u
_mg_engine=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$_mg_engine/lib.sh"
_mg_root=$(gate_root)
_mg_real=$(resolve_real_mill "$_mg_root") || {
  printf 'mill-gate: no Mill to run — neither %s/mill nor a mill on PATH\n' "$_mg_root" >&2
  exit 127
}
MILL_OUTPUT_DIR=$(dsh_agent_output_dir "$_mg_root")
export MILL_OUTPUT_DIR
exec "$_mg_real" --no-daemon "$@"
```

`git add --chmod=+x kit/harness/mill-gate.sh` after creating it (and `chmod +x`).

`lib.sh`: rename the body of today's `resolve_mill` into `resolve_real_mill` (unchanged), then:

```sh
# resolve_mill <root>: the Mill the ENGINE runs — mill-gate.sh, which runs resolve_real_mill's Mill with
# --no-daemon in the agent's output directory. Exit 1 when there is no Mill at all, as before, so callers keep
# their own fail-closed wording. Callers run it as "$mill" args… from the root.
resolve_mill() {
  resolve_real_mill "${1:-}" >/dev/null || return 1
  _rm_eng=${here:-$(gate_root)/.dsh/engine}
  [ -f "$_rm_eng/mill-gate.sh" ] || _rm_eng=$(gate_root)/.dsh/engine
  printf '%s\n' "$_rm_eng/mill-gate.sh"
}

# dsh_agent_output_dir [root]: the agent's Mill output directory — the contract's `agentOutputDir`, else out-agent.
# A value that is not a plain relative path (absolute, a `..` segment, a space, empty) is refused: the default is
# printed and the exit status is 3, so check-harness can name it.
dsh_agent_output_dir() {
  _ao_v=$(dsh_contract_get agentOutputDir "${1:-$(gate_root)}" 2>/dev/null)
  _ao_rc=$?
  if [ "$_ao_rc" != 0 ]; then printf 'out-agent\n'; return 0; fi
  case "/$_ao_v/" in
    *'/../'*|*'/./'*|//) printf 'out-agent\n'; return 3 ;;
  esac
  if printf '%s\n' "$_ao_v" | grep -Eqx '[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*'; then
    printf '%s\n' "$_ao_v"
    return 0
  fi
  printf 'out-agent\n'
  return 3
}
```

(Check `dsh_contract_get`'s behaviour for a present key with an empty value; if it returns 1 for that, treat "key present but empty" via `grep -Eq '^[[:space:]]*agentOutputDir[[:space:]]*=' "$root/.dsh/contract"` → rc 3. The lib-test row for `''` decides.)

`module-map.sh` line ~90: replace `./mill --ticker false moduleMap` with the resolved wrapper. module-map.sh already sources lib.sh (verify; if not, source it the way `hooks/*.sh` do) and runs from the root:

```sh
mm_mill=$(resolve_mill "$root") || mm_mill=''
if [ -n "$mm_mill" ] && (cd "$root" && "$mm_mill" --ticker false moduleMap 2>/dev/null) > "$tmp" 2>/dev/null && map_clean "$tmp"; then
```

and update the two `cannot_decide=` messages that quote `./mill --ticker false moduleMap` only if they would now be false (they describe the human's command; keep them).

`turn-end.sh` ~1371: `"$mill" --no-server --ticker false …` → `"$mill" --ticker false …` (the wrapper adds `--no-daemon`; Mill rejects nothing here, but two server flags are noise).

- [ ] **Step 5: Update expectations that differ only by `--no-daemon`**

Run: `cd kit/harness/tests && sh run.sh 2>&1 | grep '^FAIL' ; sh module-map-test.sh 2>&1 | grep '^FAIL'`
For every failing case whose only difference is the wrapper's `--no-daemon`, update its expectations:
`sed -i '' 's/^mill /mill --no-daemon /' kit/harness/tests/cases/<case>/expect.loggrep` (GNU sed: `sed -i`), and the matching strings in that case's `post_gate` and in `module-map-test.sh`. Do NOT edit a case that fails for any other reason — report it.

- [ ] **Step 6: Run everything**

Run (both shells): `for s in sh dash; do for t in run.sh lib-test.sh module-map-test.sh feedback-test.sh health-test.sh install-test.sh vocabulary-test.sh instructions-test.sh; do echo "$s $t: $($s $t 2>&1 | tail -1)"; done; done` (from `kit/harness/tests`, after `git add` of new/changed cases).
Expected: 0 failed everywhere.

- [ ] **Step 7: Commit**

```bash
git add kit/harness/mill-gate.sh kit/harness/lib.sh kit/harness/module-map.sh kit/harness/hooks/turn-end.sh kit/harness/tests/bin/mill kit/harness/tests/lib-test.sh kit/harness/tests/module-map-test.sh kit/harness/tests/cases
git commit -m "kit(harness): every Mill the engine starts runs through mill-gate.sh (--no-daemon, agent output dir)

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 2: Contract commands through the wrapper

**Files:**
- Modify: `kit/harness/lib.sh` (add `dsh_gate_command`)
- Modify: `kit/harness/hooks/turn-end.sh:~1135` (turnEndTests `te_cmd`), `:~1536` (`holdout_cmd`)
- Modify: `kit/harness/hooks/post-edit.sh:~271` (`ft`)
- Test: `kit/harness/tests/lib-test.sh`, new fixture cases

**Interfaces:**
- Consumes: Task 1's `mill-gate.sh` and `resolve_mill`.
- Produces: `dsh_gate_command <cmd> [engine dir]` → prints `<cmd>` with its leading `./mill` or `mill` word (after optional leading whitespace and `NAME=value` assignments) replaced by the single-quoted absolute path of `<engine>/mill-gate.sh`; exit 0 when replaced, exit 1 (printing `<cmd>` unchanged) when the first word is anything else. Engine dir default: `${here:-$(gate_root)/.dsh/engine}`.

- [ ] **Step 1: Write failing lib-test rows**

```sh
gcmd() { /bin/sh -c '. "$1/lib.sh"; dsh_gate_command "$2" "$3"; printf "rc=%s\n" "$?"' _ "$engine" "$1" "$2"; }
E=/x/eng
is "gate cmd: ./mill" "'/x/eng/mill-gate.sh' -j 1 --ticker false core.test
rc=0" "$(gcmd './mill -j 1 --ticker false core.test' "$E")"
is "gate cmd: mill on PATH" "'/x/eng/mill-gate.sh' core.test
rc=0" "$(gcmd 'mill core.test' "$E")"
is "gate cmd: leading assignment stays" "FOO=1 '/x/eng/mill-gate.sh' x
rc=0" "$(gcmd 'FOO=1 ./mill x' "$E")"
is "gate cmd: leading blanks" "'/x/eng/mill-gate.sh' x
rc=0" "$(gcmd '   ./mill x' "$E")"
is "gate cmd: other command untouched" "sh .dsh/holdout-stub.sh
rc=1" "$(gcmd 'sh .dsh/holdout-stub.sh' "$E")"
is "gate cmd: ./millx is not mill" "./millx y
rc=1" "$(gcmd './millx y' "$E")"
is "gate cmd: quote in engine path" "'/x/it'\\''s/mill-gate.sh' y
rc=0" "$(gcmd './mill y' "/x/it's")"
# executes: an engine dir with a space, a mill-gate.sh that echoes its args
sp=$(mktemp -d)/"eng dir"; mkdir -p "$sp"; printf '#!/bin/sh\necho "ran: $*"\n' > "$sp/mill-gate.sh"; chmod +x "$sp/mill-gate.sh"
is "gate cmd: runs through a spaced engine path" "ran: -j 1 a.test" "$(sh -c "$(/bin/sh -c '. "$1/lib.sh"; dsh_gate_command "./mill -j 1 a.test" "$2"' _ "$engine" "$sp")")"
```

- [ ] **Step 2: Write failing fixture cases**

- `turn-end-contract-tests-through-gate/`: copy `turn-end-downstream-green/`; set its `root/.dsh/contract` `turnEndTests = ./mill -j 1 --ticker false <module>.test` (no te-stub; the PATH stub mill answers green), keep `post_git`; `expect.code` 0; `expect.loggrep`: `mill --no-daemon -j 1 --ticker false core.test`.
- `turn-end-holdout-through-gate/`: copy `turn-end-holdout-two-failures/`; contract `holdout = ./mill -j 1 --ticker false holdout.test`; remove `root/.dsh/holdout-stub.sh`; delete the copied `root/mill`; `post_gate` replaced by `grep -q -- '--no-daemon -j 1 --ticker false holdout.test' "$MILL_STUB_LOG" || { echo FAIL; exit 1; }; echo ok`; `expect.grep`: `holdout:`; `expect.code` 0. (Adjust `expect.grep` to what the stub's empty output yields — `holdout: result unreadable` — the case asserts the ROUTE, not the result.)
- `post-edit-fasttests-through-gate/`: copy `post-edit-fasttests-green/`; contract `fastTests = ./mill -j 1 --ticker false <module>.test.testOnly '*Props'`; remove its fast-stub use; `expect.loggrep`: `mill --no-daemon -j 1 --ticker false`.

- [ ] **Step 3: Run to verify they fail**

Run: `sh lib-test.sh 2>&1 | grep 'gate cmd'; RUN_CASES='*through-gate*' sh run.sh 2>&1 | tail -4`
Expected: rows FAIL (`dsh_gate_command: not found`); 3 cases FAIL (log shows `mill -j 1 …` without `--no-daemon`).

- [ ] **Step 4: Implement**

```sh
# dsh_gate_command <cmd> [engine dir]: a contract command the engine is about to run, with its Mill routed through
# mill-gate.sh (spec 2026-10-02 §4.2): the leading `./mill` or `mill` word — after any leading blanks and
# NAME=value assignments, which stay in front — becomes the single-quoted path of <engine>/mill-gate.sh.
# Exit 1, printing <cmd> unchanged, when the first word is anything else (check-harness notes such commands).
dsh_gate_command() {
  _gc_eng=${2:-${here:-$(gate_root)/.dsh/engine}}
  _gc_rest=${1:-}
  _gc_rest=${_gc_rest#"${_gc_rest%%[! 	]*}"}
  _gc_pre=''
  while :; do
    _gc_w=${_gc_rest%%[ 	]*}
    case "$_gc_w" in
      [A-Za-z_]*=*)
        case "${_gc_w%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
        _gc_pre="$_gc_pre$_gc_w "
        _gc_rest=${_gc_rest#"$_gc_w"}
        _gc_rest=${_gc_rest#"${_gc_rest%%[! 	]*}"} ;;
      *) break ;;
    esac
  done
  case "$_gc_w" in
    ./mill|mill)
      _gc_q=$(printf '%s' "$_gc_eng/mill-gate.sh" | sed "s/'/'\\\\''/g")
      printf "%s'%s'%s\n" "$_gc_pre" "$_gc_q" "${_gc_rest#"$_gc_w"}"
      return 0 ;;
  esac
  printf '%s\n' "${1:-}"
  return 1
}
```

Call sites (each right after the command is read, before it is run):
- turn-end turnEndTests: after `te_cmd=$(dsh_contract_for_module turnEndTests "$te_mod" "$root") || return 0` add `te_cmd=$(dsh_gate_command "$te_cmd" "$here")`.
- turn-end holdout: after `holdout_cmd=$(dsh_contract_get holdout "$root" 2>/dev/null) || holdout_cmd=''` add `[ -n "$holdout_cmd" ] && holdout_cmd=$(dsh_gate_command "$holdout_cmd" "$here")`.
- post-edit fastTests: inside the `if … ft=$(dsh_contract_for_module fastTests …); then` add `ft=$(dsh_gate_command "$ft" "$here")` before `ft_out=…`.
(`dsh_gate_command` exits 1 for a non-Mill command; `$(…)` still captures the unchanged text — do not chain `||` on it.)

- [ ] **Step 5: Run everything (both shells), as Task 1 Step 6. Expected 0 failed.**

- [ ] **Step 6: Commit**

```bash
git add kit/harness/lib.sh kit/harness/hooks/turn-end.sh kit/harness/hooks/post-edit.sh kit/harness/tests/lib-test.sh kit/harness/tests/cases
git commit -m "kit(harness): contract Mill commands run through mill-gate.sh

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 3: The sandbox settings — seed, and check-harness verifies them

**Files:**
- Modify: `kit/harness/seed/cc-settings.json`, `kit/harness/seed/contract` (commented `agentOutputDir` line)
- Modify: `kit/harness/lib.sh` (add `dsh_json_get`, `dsh_holdout_target`, `dsh_sandbox_checks`)
- Modify: `kit/harness/check-harness.sh` (map the rows, after the holdout rows at ~601)
- Test: `kit/harness/tests/lib-test.sh`, `kit/harness/tests/install-test.sh`

**Interfaces:**
- Consumes: Task 1's `dsh_agent_output_dir` (rc 3 = invalid value).
- Produces: `dsh_json_get <file> <dotted.path>` → prints the value at the path as compact JSON (`true`, `"out-agent"`, `["a","b"]`), empty when absent; exit 0; exit 2 when neither jq nor python3 exists; exit 3 when the file is not valid JSON.
- Produces: `dsh_holdout_target [root]` → the first dotted segment of the last word of the contract's `holdout =` line (the derivation `tool-policy.sh` ~830 uses), empty + exit 1 when there is no holdout line.
- Produces: `dsh_sandbox_checks [root]` → `ok|FAIL|note TAB <message>` rows, exit 1 when any FAIL (the `dsh_holdout_checks` shape).

Rows `dsh_sandbox_checks` emits, in order:
1. No `holdout =` line → one `note` "no sealed holdout suite in the contract — the sandbox is not required"; stop.
2. `dsh_agent_output_dir` rc 3 → `FAIL` "agentOutputDir = <value> is not a plain relative path; the engine uses out-agent".
3. `.claude/settings.json` missing → `FAIL` ".claude/settings.json is missing — copy .dsh/cc-settings.json there (a human step: the file is frozen)"; stop.
4. `dsh_json_get` rc 2 → `FAIL` "cannot read .claude/settings.json: neither jq nor python3 is on PATH"; rc 3 → `FAIL` "… is not valid JSON"; stop.
5. For each required key with its exact value (Global Constraints): `ok` "<key> = <value>" or `FAIL` "<key> must be <value> (found <found or absent>) — add \"<key>\": <value>".
6. `env.MILL_OUTPUT_DIR` ≠ agent dir → `FAIL` naming both.
7. `denyRead` must contain `./out/mill-daemon`, `./<agent dir>/<holdout target>`, and `./<path>` for each sealed row of `dsh_frozen_paths` (prefix rows give their directory, exact rows the file) → one `ok` per entry present, one `FAIL` per entry missing: "sandbox.filesystem.denyRead lacks \"./holdout\" — the sealed row holdout/**".
8. `allowWrite` lacks one of the three cache paths → `note` (the build fails loudly anyway).
9. `git check-ignore -q <agent dir>/x` fails → `note` "<agent dir>/ is not gitignored — add /<agent dir>/ to .gitignore".
10. For each contract key the engine executes (`turnEndTests`, `fastTests`, `holdout`) whose command's first word (after blanks and `NAME=value`) is not `./mill` or `mill` → `note` "<key> = <cmd> does not start with ./mill, so the engine cannot route it through mill-gate.sh — a Mill server it starts is outside the seal". Use `dsh_gate_command`'s exit status (1 = not routed).

- [ ] **Step 1: Write failing lib-test rows**

Build a scratch root per scenario (copy the `hcroot` setup at lib-test ~1161: contract with `holdout = ./mill -j 1 --ticker false holdout.test`, frozen-paths with `sealed	holdout/**	…` and `sealed	.dsh/.state/holdout.log	…`). Helper:

```sh
sbc() { /bin/sh -c '. "$1/lib.sh"; dsh_sandbox_checks "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
good_settings() { cat > "$1/.claude/settings.json" <<'JSON'
{ "env": { "MILL_OUTPUT_DIR": "out-agent" },
  "sandbox": { "enabled": true, "allowUnsandboxedCommands": false, "failIfUnavailable": true,
    "network": { "allowLocalBinding": true },
    "filesystem": { "allowWrite": ["~/.cache/mill", "~/.cache/coursier", "~/Library/Caches/Coursier"],
      "denyRead": ["./out/mill-daemon", "./out-agent/holdout", "./holdout", "./.dsh/.state/holdout.log"] } } }
JSON
}
```

Rows (assert with `case "$out" in *'<text>'*) ok …;; *) bad …;; esac`, the file's existing style):
- good settings → contains no `FAIL`, ends `rc=0`;
- `"allowUnsandboxedCommands": true` → `FAIL` containing `sandbox.allowUnsandboxedCommands must be false`, `rc=1`;
- denyRead without `./holdout` → `FAIL` containing `lacks "./holdout"`;
- `env.MILL_OUTPUT_DIR` = `out` → `FAIL` naming `out` and `out-agent`;
- no settings file → `FAIL` containing `.claude/settings.json is missing`;
- contract without a holdout line → exactly one `note`, `rc=0`;
- `agentOutputDir = ../x` → `FAIL` containing `agentOutputDir = ../x`;
- no jq and no python3: run with `PATH` set to a scratch dir holding only symlinks to `sh`, `grep`, `sed`, `awk`, `cat`, `git`, `tr`, `dirname`, `mktemp` → `FAIL` containing `neither jq nor python3`;
- invalid JSON (`{`) → `FAIL` containing `not valid JSON`.
- `dsh_json_get` rows: `true` for `sandbox.enabled`, `"out-agent"` for `env.MILL_OUTPUT_DIR`, empty for `sandbox.nope`.
- `dsh_holdout_target` rows: `holdout` for the scratch contract; empty + rc 1 without a holdout line.

`install-test.sh`: one row — after a fresh install the seeded `.dsh/cc-settings.json` has `sandbox.enabled` `true` and `env.MILL_OUTPUT_DIR` `"out-agent"` (via `dsh_json_get`).

- [ ] **Step 2: Run to verify they fail** (`sh lib-test.sh 2>&1 | grep -c FAIL` > 0; install-test row FAIL).

- [ ] **Step 3: Implement**

`dsh_json_get`: jq form `jq -c --arg p "$2" 'getpath($p | split(".")) // empty'` (note: `// empty` drops `false` — use `getpath(...) | if . == null then empty else . end` instead); python3 form:

```sh
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."):
    d = d.get(k) if isinstance(d, dict) else None
if d is not None: print(json.dumps(d, separators=(",",":")))' "$1" "$2"
```

JSON validity: jq `-e . >/dev/null` / python3 `json.load` failing → exit 3. A list membership test for denyRead/allowWrite: read the array once with `dsh_json_get`, then test `case "$arr" in *'"./holdout"'*)`.

`dsh_holdout_target`: copy tool-policy's derivation (`_ho_sel=${_ho_cmd##* }; _ho_target=${_ho_sel%%.*}`), defaulting to `holdout` when the derived target is empty, exactly as tool-policy does.

`dsh_sandbox_checks`: the rows above. `check-harness.sh`: a block like the holdout one:

```sh
# The structural holdout seal (spec 2026-10-02 §4.4): the agent's sandbox settings, same row shape as above.
sb_rows=$(dsh_sandbox_checks "$repo" 2>&1) || :
while IFS="$tab" read -r sb_kind sb_msg; do
  [ -n "$sb_kind" ] || continue
  case "$sb_kind" in
    ok) ok "$sb_msg" ;;
    FAIL) bad "$sb_msg" ;;
    note) note "$sb_msg" ;;
    *) bad "dsh_sandbox_checks printed a row this check does not understand: $sb_kind $sb_msg" ;;
  esac
done <<EOF
$sb_rows
EOF
```

Seed `cc-settings.json`: add, beside `"hooks"`, the `env` and `sandbox` objects of the good settings above (they match the mill recipe's conventional `holdout` module; check-harness tells a project with another target what to change). Seed `contract`: add the comment line `# agentOutputDir = out-agent   # the agent's Mill output directory (spec 2026-10-02); default out-agent`.

- [ ] **Step 4: Run everything (both shells). Expected 0 failed.** check-harness on the template itself must stay green (no holdout line in the template's contract → one note).

- [ ] **Step 5: Commit** (`lib.sh`, `check-harness.sh`, `seed/cc-settings.json`, `seed/contract`, `tests/lib-test.sh`, `tests/install-test.sh`).

---

### Task 4: health says when the seal is text-only

**Files:**
- Modify: `kit/harness/hooks/health.sh` (after the non-Mill note, ~line 236)
- Test: new cases `kit/harness/tests/cases/health-sandbox-*`

**Interfaces:**
- Consumes: Task 3's `dsh_json_get`, `dsh_holdout_target`.
- Produces: env seam `DSH_SANDBOX_PROBE` (`ok` | `none`) overriding the platform probe, for tests only.

Behaviour: only when the contract has a holdout line. Platform probe (unless `DSH_SANDBOX_PROBE` is set): `uname -s` = `Darwin` → ok when `sandbox-exec` is on PATH; `Linux` → ok when both `bwrap` and `socat` are; anything else → none. Then one line, at most:
- probe none → `DSH harness: note -- the holdout seal is text-only in this session: no OS sandbox on this platform (<uname>); see .dsh/engine/README.md "Structural holdout seal"`
- settings missing, unreadable, or `sandbox.enabled` not `true` → `DSH harness: note -- the holdout seal is text-only in this session: .claude/settings.json does not enable the sandbox; run sh .dsh/engine/check-harness.sh`
- otherwise nothing.

- [ ] **Step 1: Failing cases** — copy `health-non-mill-note/` (it shows how a health case is laid out) into:
  - `health-sandbox-off-note/`: contract with a holdout line, `.claude/settings.json` = `{}`, env `DSH_SANDBOX_PROBE=ok`; `expect.grep`: `holdout seal is text-only in this session: .claude/settings.json does not enable the sandbox`;
  - `health-sandbox-platform-note/`: good settings (Task 3's), env `DSH_SANDBOX_PROBE=none`; `expect.grep`: `no OS sandbox on this platform`;
  - `health-sandbox-on-quiet/`: good settings, `DSH_SANDBOX_PROBE=ok`; `post_gate`: `! grep -q 'holdout seal is text-only' "$GATE_OUT_FILE"`;
  - `health-sandbox-no-holdout-quiet/`: no holdout line, settings `{}`, `DSH_SANDBOX_PROBE=none`; same `post_gate`.
- [ ] **Step 2: Run, verify the first two FAIL.**
- [ ] **Step 3: Implement** in health.sh (`printf` lines like the non-Mill note; never change the exit code).
- [ ] **Step 4: Run everything (both shells). Expected 0 failed.**
- [ ] **Step 5: Commit** (`hooks/health.sh`, `tests/cases/health-sandbox-*`).

---

### Task 5: Documentation

**Files:**
- Modify: `kit/harness/README.md`, `kit/recipes/mill.md`
- Possibly: `kit/harness/hooks/feedback.sh` (see last step)

- [ ] **Step 1: README** — a section "Structural holdout seal" stating: the invariant (every Mill server the agent can find runs inside its sandbox, and the sandbox cannot read the holdout); the settings block (exact keys); `mill-gate.sh` and `dsh_gate_command` (direct calls and contract commands); `agentOutputDir`; the check-harness rows and health lines (add them to the existing tables of section titles/lines); `DSH_SANDBOX_PROBE` (tests only); the residuals of spec §5 verbatim in substance (port-scan to the human's server, file tools and MCP servers outside the sandbox, dependency downloads, native Windows). Update the blind-spot bullet that says run-time-built selectors and non-shell interpreters reach the seal: true only where the sandbox is off.
- [ ] **Step 2: recipes/mill.md** — the holdout section: the human copies `.dsh/cc-settings.json`'s `env`/`sandbox` blocks into `.claude/settings.json`, adds `/out-agent/` to `.gitignore`, runs `sh .dsh/engine/check-harness.sh`; the first agent build fills `out-agent/`; a terminal `./mill` keeps using `out/`.
- [ ] **Step 3: feedback launcher failure** — when Mill's launcher fails (`Mill launcher failed`, `server launch failed`), feedback.sh currently renders `UNREADABLE`. If a one-line adapter pattern makes it an INFRA record naming the cause, add it with a feedback-test row; otherwise leave it and report it as a deferred minor.
- [ ] **Step 4: Run everything (both shells); commit** (`README.md`, `kit/recipes/mill.md`, and feedback files if touched).

---

### Task 6 (controller, not a subagent): live verification and cost

Run after Tasks 1–5 are merged on the branch, in a scratch clone of skreeep2 with the branch's engine installed (`sh <template>/kit/harness/install.sh .`), modules.tsv copied, and `.claude/settings.json` = skreeep2's hooks + the seed's `env`/`sandbox` blocks:

1. Gated headless `claude -p` (sonnet, tools Bash/Write/Read): `./mill holdout.test`, `H=hold; H="${H}out"; ./mill "$H.test"`, the Python `subprocess` route, `cat holdout/...`, `ls out-agent/holdout`, `cat .dsh/.state/holdout.log`; expected all fail with `Operation not permitted` or a gate refusal, and no holdout test name in the output.
2. A Mill server started from an unsandboxed shell in `out/` (`./mill version`) before the session: the agent's `MILL_OUTPUT_DIR=out ./mill holdout.test` and plain `./mill holdout.test` fail; `pgrep -fl MillDaemonMain` after the session shows no server under `out-agent` that was started outside the sandbox (the agent's own may exist).
3. Normal work sandboxed: `./mill signals.compile`, `./mill signals.test`, a source edit + `core.compile`.
4. A turn that ends: the Stop hook's holdout line `holdout: N passed, M failed`; `pgrep` shows the gate left no server.
5. Cost: turn-end and post-edit wall time on a one-file `core` edit, old engine vs new (3 runs each).
6. Dependency download inside the sandbox: add a new test-scope dependency to a scratch module and compile; record whether it downloads; if not, record the documented remedy working.

Record every number in `raw/llm-scala-fusion/<date>-local-structural-holdout-seal.md` (scala-coding-guidelines) for the wiki update.
