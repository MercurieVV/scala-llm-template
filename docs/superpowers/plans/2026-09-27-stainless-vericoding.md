# Stainless Vericoding (template half) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the kit a Stainless Mill recipe, a gate stage that verifies registered kernel files at turn-end while blocking any agent edit to a human-owned `require`/`ensuring`/`decreases`, and a `vericoding` skill — measured against the real Stainless tool first.

**Architecture:** Task 1 lifts ScalaSemanticMCP's Stainless wiring into `kit/recipes/mill/` (a `StainlessModule` trait + a generalised `stainless-verify.sh`) and runs the three pilot contracts and a `???` body through the real tool, keeping its output as fixtures. Task 2 adds the frozen registry `.dsh/policy/kernels.tsv` to the engine (parse, check-harness rules, seeds). Task 3 snapshots `contract_clauses` at SessionStart and adds the turn-end vericoding stage: contract guard, then `<module>.stainlessVerify`. Task 4 ships the skill and the docs.

**Tech Stack:** POSIX `sh` (dash-clean), jq with python3 fallback (the engine's existing JSON readers), Mill 1.1.8, Stainless standalone 0.9.9.3 (dotty), ScalaSemanticMCP `contract_clauses` (one-shot `call`), scala-cli (`Setup.scala`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-09-27-stainless-vericoding-design.md` (§1 items 2–4, §2 feasibility, §3, §4). The engine's conventions are in `kit/harness/README.md`.

## Global Constraints

- Work in the template worktree only; the engine is edited in `kit/harness/` and is vendored into projects later (not in this plan).
- The gate never silently passes: every new condition **blocks**, is a named finding note (`section note`), or is a named degradation.
- Contract guard: a changed clause `shape`, or a removed clause/def-with-contract, **blocks** with "contracts are the human's — ask in chat"; a new def with a contract is allowed; no snapshot → named note (the Stainless check still runs); tool failure / launcher missing → named stand-down of the guard.
- Stainless: exit 1 → **block** listing each `invalid` VC (capped) with remedy "fix the body; if the contract is wrong, ask the human"; `unknown` VCs → named note; exit 2 → named stand-down naming the cause.
- The stage runs only when the turn touched a file listed in `.dsh/policy/kernels.tsv`, after the module's compile/checks, and not for a module whose checks already blocked this turn.
- `kernels.tsv`: `<file> TAB <module> TAB <reason>`, `#` comments, frozen, seeded header-only.
- `stainlessVerify --targets <file,file,…>` (flag form — Mill 1.1.8 rejects positional command args). Script exit 0 no `invalid`, 1 any `invalid`, 2 tool missing/setup failure; env overrides `STAINLESS_VERSION` (default `0.9.9.3`), `STAINLESS_TIMEOUT`, `STAINLESS_CACHE_DIR`.
- Contract snapshot: `.dsh/.state/contracts-<session>.tsv`, taken at SessionStart over every registered kernel file (dirty or not); a second SessionStart keeps the first record.
- Every engine script: POSIX sh, no `local`, no arrays, no `set -e` in hooks; `dash -n` clean; `sh tests/run.sh` and `dash tests/run.sh` green; every `tests/*-test.sh` green.
- Commits end with `Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU`; never a `Co-Authored-By` trailer. Let the pre-commit hook run; never `--no-verify`.

## Review Focus

1. A kernel file whose module's compile failed this turn: the stage must not run Stainless on it (it would report noise) — pinned in Task 3 (`vericoding-skipped-when-module-blocked`).
2. A kernel file that is registered but no longer exists (deleted/renamed by the agent): must block or fail loudly, never skip — pinned in Task 2 (check-harness FAIL) and Task 3 (`vericoding-kernel-deleted-blocks`).
3. A contract snapshot taken while the launcher was down (empty/partial snapshot): the guard must say it cannot compare, not report every contract as "new" and pass — pinned in Task 3 (`vericoding-no-snapshot-notes`).
4. Stainless output with ANSI colour codes and very long counterexamples: the block must strip colour and stay bounded — pinned in Task 3 (`vericoding-invalid-blocks` uses a coloured fixture from Task 1).
5. Two kernel files in one module, only one touched: Stainless must still verify both (a body change can break a lemma the other file uses) — pinned in Task 3 (`vericoding-runs-all-module-kernels`).

---

### Task 1: The Stainless Mill recipe, measured against the real tool

**Files:**
- Create: `kit/recipes/mill/Stainless.mill`, `kit/recipes/mill/stainless-verify.sh`
- Create: `kit/recipes/mill/stainless-feasibility.md` (the measured record)
- Create: `kit/harness/tests/fixtures/stainless/{valid.txt,invalid.txt,unknown.txt}` (real tool output, as captured; `unknown.txt` only if the tool produced one — else a ruling line says so)
- Modify: `kit/recipes/mill.md` (new section `## 8. Stainless (vericoding)` after `## 7. The gate's tasks`)

**Interfaces:**
- Consumes: ScalaSemanticMCP's `scripts/stainless-verify.sh` and its `build.mill` lines 253–270 (read: `/Users/viktorskalinins/IdeaProjects/my/ScalaSemanticMCP`), the wiki recipe `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/wiki/stainless-verification/stainless-mill-integration.md`.
- Produces: `trait StainlessModule` with `def stainlessVerify(targets: String): Command[Unit]` (named arg `--targets`, comma-separated root-relative paths); the script contract above; three fixture files the engine's parser (Task 3) reads; a feasibility verdict for K1–K3.

- [ ] **Step 1: Write the script** — start from ScalaSemanticMCP's `scripts/stainless-verify.sh` (read it). Changes: targets come from the arguments (`"$@"`, at least one required; exit 2 with a usage line otherwise) instead of a hard-coded `TARGET`; cache default `${STAINLESS_CACHE_DIR:-$HOME/.cache/scala-llm-kit/stainless}`; any download/unzip/launcher failure exits **2** with a named reason on stderr; after the run, print the summary line, then exit 1 if the summary's `invalid:` count > 0, else 0; if no summary line can be found, exit 2 ("no Stainless summary in the output"). Keep ANSI stripping for the summary parse, but pass the tool's own output through unchanged (the engine strips colour itself).

- [ ] **Step 2: Write `Stainless.mill`**

```scala
package build.buildKit

import mill._
import mill.scalalib._
import build.BuildPaths

/** Stainless verification for a module whose kernels are verified in place (spec 2026-09-27 §1). The library
  * jar is an unmanaged dependency at `<module>/lib/stainless-library.jar` (from the standalone
  * distribution); `stainlessVerify --targets a.scala,b.scala` runs `scripts/stainless-verify.sh` on
  * exactly those files. Exit codes are the script's: 0 no invalid VC, 1 an invalid VC, 2 setup failure.
  */
trait StainlessModule extends ScalaModule {
  def stainlessJar = Task.Source(moduleDir / "lib" / "stainless-library.jar")
  override def unmanagedClasspath = Task { super.unmanagedClasspath() ++ Seq(stainlessJar()) }

  def stainlessVerify(targets: String) = Task.Command {
    val script = BuildPaths.repoRoot / "scripts" / "stainless-verify.sh"
    val files = targets.split(",").map(_.trim).filter(_.nonEmpty).toSeq
    if (files.isEmpty) sys.error("stainlessVerify: --targets names no file")
    val rc = os.proc("sh", script.toString, files).call(cwd = BuildPaths.repoRoot, check = false, stdout = os.Inherit, stderr = os.Inherit)
    if (rc.exitCode != 0) sys.error(s"stainlessVerify failed (exit ${rc.exitCode})")
  }
}
```

If Mill 1.1.8 needs a different `unmanagedClasspath` override form or `os.Inherit` spelling, use what compiles and record a `Ruling:` line. The Mill task's own exit when the script exits 1 vs 2 must remain distinguishable to a caller: record in `stainless-feasibility.md` what `./mill …stainlessVerify` prints and exits for script exit 1 and for exit 2 (the engine in Task 3 distinguishes them by the script's own marker lines, see Step 5).

- [ ] **Step 3: Assemble a scratch project and measure** (under `mktemp -d`, never in the worktree): the recipe's §1 head fragment + `buildKit/package.mill` + `buildKit/Stainless.mill` + `scripts/stainless-verify.sh`, a `./mill` wrapper (`git -C /Users/viktorskalinins/IdeaProjects/skreeep2 show master:mill`), `.mill-version` `1.1.8`, and `object core extends ScalaModule with StainlessModule { def scalaVersion = "3.8.4" }` with `core/lib/stainless-library.jar` copied from `/Users/viktorskalinins/IdeaProjects/my/ScalaSemanticMCP/analysis/lib/stainless-library.jar`. Kernel files under `core/src/`:
  - `Valid.scala`: `import stainless.lang.*` + `object Valid { def inc(x: BigInt): BigInt = { require(x >= 0); x + 1 } ensuring (r => r > x) }`
  - `Invalid.scala`: same shape with `ensuring (r => r < x)` (must be invalid).
  - `Pilot.scala`: K1 `toPcm16`, K2 `framesToNanos`, K3 `samplesToNanos` exactly as the spec §2 states them (bodies as today in skreeep2: `git -C /Users/viktorskalinins/IdeaProjects/skreeep2 show master:core/src/com/github/mercurievv/skreeep2/audio/AudioFormat.scala` and `…/RelativeTime.scala`), each `def` in `object PureKernels`.
  - `Hole.scala`: a `require`/`ensuring` contract with body `???`.

  Run `./mill --no-server --ticker false core.stainlessVerify --targets core/src/Valid.scala`, then `…Invalid.scala`, then `…Pilot.scala`, then `…Hole.scala`, each with output to a file. Expected: Valid exit 0; Invalid exit non-zero with at least one `invalid` VC and a counterexample.

- [ ] **Step 4: Record the verdict** in `kit/recipes/mill/stainless-feasibility.md`: tool version, platform, per-file exit codes and summary lines; for K1, K2, K3 each: `valid` / `invalid` (with counterexample) / `unknown` / `unsupported` (with the tool's message); what `???` produces. **If any of K1–K3 is not `valid`**, do not reformulate it yourself: write the exact tool output into the record and report `DONE_WITH_CONCERNS` naming which contract failed and why — the human decides the reformulation (spec §2).

- [ ] **Step 5: Keep fixtures** — copy the raw captured outputs (Valid → `valid.txt`, Invalid → `invalid.txt`, an `unknown` run → `unknown.txt` if one occurred) into `kit/harness/tests/fixtures/stainless/`. Note in the feasibility record the exact line patterns that identify: an invalid VC line, its counterexample lines, an unknown VC line, and the summary line (e.g. regexes). Task 3 parses exactly these.

- [ ] **Step 6: Recipe section** — append `## 8. Stainless (vericoding)` to `kit/recipes/mill.md`: copy `Stainless.mill` into `buildKit/`, `stainless-verify.sh` into `scripts/`, the jar into `<module>/lib/`; mix `StainlessModule` into the kernel's module; register kernels in `.dsh/policy/kernels.tsv`; add `<module>.stainlessVerify --targets …` to `prePush`; link `stainless-feasibility.md` as "how this recipe was checked".

- [ ] **Step 7: Commit**

```bash
git add kit/recipes/mill/Stainless.mill kit/recipes/mill/stainless-verify.sh kit/recipes/mill/stainless-feasibility.md kit/recipes/mill.md kit/harness/tests/fixtures/stainless
git commit -m "kit(mill): Stainless recipe — StainlessModule and a targets-taking verify script, measured on the real tool

Claude-Session: https://claude.ai/code/session_01WeEP7mpZmcZRnZgxUDUJsU"
```

(`kit/harness/**` is excluded from scalafmt; `.mill` files are formatted by the hook if it covers them — let it run.)

---

### Task 2: The kernel registry — `kernels.tsv`, its checks, its seed

**Files:**
- Modify: `kit/harness/lib.sh` (new helpers; `dsh_semantic_launcher` extracted from `verify-diff.sh` lines ~123–130)
- Modify: `kit/harness/verify-diff.sh` (use `dsh_semantic_launcher`)
- Modify: `kit/harness/check-harness.sh` (wire `dsh_kernel_checks` like `dsh_verify_checks` at ~line 646)
- Create: `kit/harness/seed/policy/kernels.tsv`
- Modify: `kit/harness/seed/frozen-paths` (row), `kit/harness/install.sh` (seed list, line ~55)
- Test: `kit/harness/tests/lib-test.sh`, `kit/harness/tests/install-test.sh`

**Interfaces:**
- Produces:
  - `dsh_semantic_launcher` → prints the launcher path (`SCALASEMANTIC_MCP_LAUNCHER`, else `command -v scalasemantic-mcp`, else the existing fixed fallback path) — exactly verify-diff's current resolution, moved.
  - `dsh_kernels_rows <root>` → prints `<file>\t<module>` per valid row of `<root>/.dsh/policy/kernels.tsv` (comments/blank lines skipped, `\r` stripped); exit 0 even when the file is absent (prints nothing).
  - `dsh_kernel_of <root> <path>` → prints the module if `<path>` (root-relative) is a registered kernel, exit 1 otherwise.
  - `dsh_kernel_checks <root>` → rows `ok\t…`, `fail\t…`, `note\t…` (the same row protocol as `dsh_verify_checks`).

- [ ] **Step 1: Failing lib-test rows** — in `tests/lib-test.sh`, beside the memorisation-policy rows, using its `is`/scratch-root helpers:
  - `kernels_rows: parses two rows, skips comments and blanks, strips CR` — file `# hdr\n\ncore/src/K.scala\tcore\tpilot\r\nsong/src/S.scala\tsong\tx\n` → `core/src/K.scala\tcore` and `song/src/S.scala\tsong`.
  - `kernel_of: registered path → module; other path → exit 1`.
  - `kernel_checks: absent file → note "no .dsh/policy/kernels.tsv — no kernels are verified"`.
  - `kernel_checks: a row with 2 fields → fail naming the line`; `a row whose file does not exist → fail naming it`; `a row whose module is not in .dsh/.state/modules.tsv → fail naming it` (write a modules.tsv in the scratch root with `core/src\tcore\tfmt`); `kernels.tsv not frozen → fail`; all well-formed → `ok`.
  - `semantic_launcher: SCALASEMANTIC_MCP_LAUNCHER wins`.
  Run: `sh tests/lib-test.sh | tail -3` → the new rows FAIL (functions undefined).

- [ ] **Step 2: Implement** in `lib.sh` (after the memorisation helpers):

```sh
# The ScalaSemantic launcher every semantic caller uses (moved from verify-diff.sh, unchanged).
dsh_semantic_launcher() {
  _sl=${SCALASEMANTIC_MCP_LAUNCHER:-}
  [ -n "$_sl" ] || _sl=$(command -v scalasemantic-mcp 2>/dev/null) || _sl=""
  [ -n "$_sl" ] || _sl=/Users/viktorskalinins/.local/bin/scalasemantic-mcp
  printf '%s\n' "$_sl"
}

# .dsh/policy/kernels.tsv — the human's frozen registry of verified kernel files (spec 2026-09-27 §1):
# `<file> TAB <module> TAB <reason>`. Prints `<file>\t<module>` per well-formed row.
dsh_kernels_rows() {
  _kr_tsv="$1/.dsh/policy/kernels.tsv"
  [ -f "$_kr_tsv" ] || return 0
  tr -d '\r' < "$_kr_tsv" | awk -F'\t' '/^[[:space:]]*(#|$)/ {next} NF >= 3 && $1 != "" && $2 != "" {print $1 "\t" $2}'
}

dsh_kernel_of() { # <root> <root-relative path>
  dsh_kernels_rows "$1" | awk -F'\t' -v p="$2" '$1 == p {print $2; found=1; exit} END {exit found ? 0 : 1}'
}
```

(Keep verify-diff's comment text about the resolution order with the moved function.) Then `dsh_kernel_checks <root>`, printing one row per finding in the `dsh_verify_checks` style (read that function first and mirror its structure): absent file → `note`; each non-comment row with fewer than 3 fields → `fail kernels.tsv:<n> needs <file> TAB <module> TAB <reason>`; file missing → `fail kernels.tsv:<n> names <file>, which does not exist`; module not a module id in `.dsh/.state/modules.tsv` (column 2) → `fail kernels.tsv:<n> names module <m>, which is not in the module map (run ./mill moduleMap)` — if modules.tsv is absent, one `note` saying the module column was not checked; `.dsh/policy/kernels.tsv` not frozen (use the same frozen-lookup `dsh_verify_checks` uses for memorisation.tsv) → `fail`; everything well-formed → `ok kernels.tsv: <N> kernel file(s) registered`. Make `verify-diff.sh` call `launcher=$(dsh_semantic_launcher)`.

- [ ] **Step 3: Wire check-harness** — beside the `dsh_verify_checks` block (~line 646), the same loop shape over `dsh_kernel_checks "$repo"` (ok → `ok`, fail → `bad`, note → `note`, anything else → `bad "dsh_kernel_checks printed a row this check does not understand: …"`). Also: when `kernels.tsv` has rows, probe the launcher answers `contract_clauses` (mirror the existing `call resolve_references` probe in `dsh_verify_checks`, via `dsh_bounded_probe 20 … call contract_clauses '{"files":[{"uri":"K.scala","source":"object K"}]}' "$root"`): no answer → `note` naming "reinstall scalasemantic-mcp (./mill installLocal in ScalaSemanticMCP) — the contract guard will stand down".

- [ ] **Step 4: Seed** — `seed/policy/kernels.tsv`:

```
# Verified kernel files (spec 2026-09-27 stainless vericoding). The human's: the agent may read, never write.
# <file, root-relative> TAB <module id> TAB <reason>
# A registered file is verified by <module>.stainlessVerify at turn-end, and its require/ensuring/decreases
# are the human's — the gate blocks any agent change to them.
```

`seed/frozen-paths`: add `.dsh/policy/kernels.tsv	the verified-kernel registry is the human's: an agent that may unregister a kernel has no proof obligation`. `install.sh`: add `policy/kernels.tsv` to the seed list (after `policy/memorisation.tsv`). `install-test.sh`: extend `fresh_install_seeds` to assert `policy/kernels.tsv` seeded, and the fresh-install checks test to expect no FAIL from kernels (absent rows → note only).

- [ ] **Step 5: GREEN** — `sh tests/lib-test.sh`, `sh tests/install-test.sh`, `dash tests/install-test.sh`, `sh tests/run.sh`, `dash tests/run.sh` (all cases pass), every `tests/*-test.sh`, `dash -n` on changed files.

- [ ] **Step 6: Commit** — `kit(harness): kernels.tsv — the frozen registry of verified kernel files, checked and seeded` (+ trailer).

---

### Task 3: Contract snapshot at SessionStart, and the turn-end vericoding stage

**Files:**
- Modify: `kit/harness/hooks/baseline.sh` (snapshot before the file-baseline logic's early exits)
- Modify: `kit/harness/lib.sh` (contract helpers)
- Modify: `kit/harness/hooks/turn-end.sh` (the stage, after the per-module checks loop, before `turnEndTests`)
- Modify: `kit/harness/tests/bin/scalasemantic-mcp` (`SCALASEMANTIC_STUB_CONTRACTS_OUT`), `kit/harness/tests/bin/mill` (`MILL_STUB_STAINLESS_OUT`, `MILL_STUB_STAINLESS_EXIT`)
- Create: fixture cases under `kit/harness/tests/cases/` (listed in Step 1)
- Test: `kit/harness/tests/lib-test.sh`

**Interfaces:**
- Consumes: Task 1 fixtures + the recorded line patterns; Task 2 `dsh_kernels_rows`, `dsh_kernel_of`, `dsh_semantic_launcher`.
- Produces:
  - `dsh_contracts_tsv <json-file>` → `<uri>\t<key>\t<kind>\t<index>\t<shape>\t<text>` per clause (kind `requires|ensuring|decreases`, index = position within `requires`, 0 for the others; text with tabs/newlines replaced by spaces); jq, else python3; exit 2 when neither exists.
  - `dsh_contract_file <sid>` → `$(state_dir)/contracts-<sid>.tsv`.
  - `dsh_contract_diff <before.tsv> <after.tsv> <uris-file>` → rows `changed\t<uri>\t<key>\t<kind>\t<old text>\t<new text>` and `removed\t<uri>\t<key>\t<kind>\t<old text>` restricted to the given uris; rows present only in `after` are ignored (new lemmas allowed).
  - `dsh_stainless_report <output-file>` → prints, colour-stripped and bounded, the invalid-VC lines with their counterexample lines, then a `unknown <N>` line; exit 0.

- [ ] **Step 1: Failing fixtures and lib rows (RED)** — stubs first:
  - `tests/bin/scalasemantic-mcp`: for `call contract_clauses`, if `SCALASEMANTIC_STUB_CONTRACTS_OUT` names a file, print it and exit 0 (checked before the generic `CALL_OUT` handling, like `LITERALS_OUT`).
  - `tests/bin/mill`: for `*.stainlessVerify*`, print `$MILL_STUB_STAINLESS_OUT`'s content if set, and exit `${MILL_STUB_STAINLESS_EXIT:-0}`; require the named `--targets` argument (exit 97 otherwise, like `--rangesFile`).

  Cases (each models an existing turn-end case for payload/env/git_init/post_git; kernels.tsv + frozen-paths row + `.dsh/.state/modules.tsv` map row live in the case's `root/`; the snapshot `root/.dsh/.state/contracts-<sid>.tsv` is written directly for the session id the payload carries):
  - `vericoding-contract-changed-blocks`: snapshot has `requires` shape A for `core/src/K.scala` `K.f`; stub answer has shape B → exit 2, grep `contracts are the human's`, the old and new text, `K.f`; `expect.millcalls` shows no `stainlessVerify`.
  - `vericoding-contract-removed-blocks`: stub answer lacks `K.f` → exit 2, grep `removed`.
  - `vericoding-new-lemma-passes`: stub answer adds `K.lemma` with a contract, `K.f` unchanged; Stainless stub exit 0 → exit 0; `expect.loggrep` `core.stainlessVerify --targets core/src/K.scala`.
  - `vericoding-invalid-blocks`: contracts unchanged; `MILL_STUB_STAINLESS_OUT` = Task 1 `invalid.txt` (copied into the case), exit 1 → exit 2, grep the invalid VC's function name and `fix the body`; no ANSI escape in output (assert via post_gate + `GATE_OUT_FILE`: `! grep -q "$(printf '\033')" "$GATE_OUT_FILE"`).
  - `vericoding-unknown-notes`: output with an unknown VC (`unknown.txt`, or a synthesised copy of `valid.txt` with the summary's unknown count > 0 if the tool gave none — say which), exit 0 → exit 0, grep `unknown`.
  - `vericoding-setup-failure-notes`: exit 2 with a `stainless-verify: …` reason → exit 0, grep `Stainless could not run` and the reason.
  - `vericoding-no-snapshot-notes`: no contracts file → exit 0 (Stainless exit 0), grep `no contract snapshot for this session`.
  - `vericoding-launcher-missing-stands-down`: `SCALASEMANTIC_MCP_LAUNCHER=/nonexistent` → exit 0, grep `contract guard stood down`; Stainless still runs (`expect.loggrep`).
  - `vericoding-not-a-kernel-runs-nothing`: turn touches `core/src/Other.scala` only → no `stainlessVerify` and no `contract_clauses` call (assert via `SCALASEMANTIC_STUB_CALL_LOG` in post_gate).
  - `vericoding-skipped-when-module-blocked`: `MILL_STUB_COMPILE_FAIL_MARK` breaks `core.compile` → exit 2 for the compile, and no `stainlessVerify` in the log.
  - `vericoding-kernel-deleted-blocks`: post_git deletes the registered kernel → exit 2, grep `registered kernel` and the path.
  - `vericoding-runs-all-module-kernels`: two kernels in `core`, turn touches one → `--targets` names both (comma-separated, in kernels.tsv order).
  - `baseline-snapshots-contracts`: SessionStart payload, stub answer file present → `root/.dsh/.state/contracts-<sid>.tsv` exists with the expected rows (post_gate); a second run keeps the first file (run_twice + a changed stub answer via mutate_between).
  - lib-test rows for `dsh_contracts_tsv` (jq path, and python3 path by `PATH` without jq if the suite has such a seam — otherwise say so), `dsh_contract_diff` (changed / removed / added-ignored / uri filter), `dsh_stainless_report` over the three fixtures.

  Run `sh tests/run.sh` → the new cases FAIL; lib rows FAIL.

- [ ] **Step 2: Implement the helpers** in `lib.sh`. `dsh_contracts_tsv` jq program:

```sh
jq -r '.files[]? | .uri as $u | .defs[]? | .key as $k |
  ((.requires // []) | to_entries[] | [$u,$k,"requires",(.key|tostring),.value.shape,.value.text]),
  (if .ensuring then [$u,$k,"ensuring","0",.ensuring.shape,.ensuring.text] else empty end),
  (if .decreases then [$u,$k,"decreases","0",.decreases.shape,.decreases.text] else empty end)
  | map(gsub("[\t\n\r]";" ")) | @tsv' "$1"
```

  with a python3 equivalent producing identical rows. `dsh_contract_diff` in awk: key rows by `uri\tkey\tkind\tindex`; for each `before` row whose uri is in the uris file: absent in `after` → `removed`; shape differs → `changed`. Also report a `removed` row for a def whose `before` has clauses and `after` has none (covered by the per-clause rule). `dsh_stainless_report`: strip `\033\[[0-9;]*m`; keep lines matching Task 1's recorded invalid-VC and counterexample patterns (bounded by `bound_lines` with `max_lines`); count unknown VCs from the summary.

- [ ] **Step 3: Snapshot at SessionStart** — in `baseline.sh`, right after `baseline=$(dsh_baseline_file "$sid")` and BEFORE the `dsh_baseline_readable` early exit: if `dsh_kernels_rows "$root"` prints any row and `$(dsh_contract_file "$sid")` does not exist, build the request `{"files":[{"uri":"<file>"},…]}` from the registered files, run `"$(dsh_semantic_launcher)" call contract_clauses "<json>" "$root"` bounded like verify-diff's calls, and write `dsh_contracts_tsv` of the answer to the contract file via a temp file + `mv`. Any failure: leave no file and append a one-line note to the hook's final `allow` message (`DSH baseline: no contract snapshot — <reason>; the contract guard will report that it cannot compare`). Never block.

- [ ] **Step 4: The turn-end stage** — after the per-module checks loop (`done < "$tmpd/mods"` at ~line 715) and before `turnEndTests`:
  1. `vk_mods=` modules owning a touched kernel: for each touched path (the loop's `$tmpd/scala` list) with `dsh_kernel_of "$root" "$path"`; also every registered kernel file that no longer exists → `blocked+1`, `section blocking "vericoding: registered kernel missing" "<path> is listed in .dsh/policy/kernels.tsv but does not exist — restore it; only the human changes the registry"`.
  2. For each such module not in `$blockmods`: 
     - Guard: touched kernel uris → call `contract_clauses` on them; convert with `dsh_contracts_tsv`; diff against `dsh_contract_file "$sid"` with `dsh_contract_diff`. Any row → `blocked+1`, `blockmods="$blockmods $m"`, `section blocking "vericoding: contracts changed in $m" "<rows rendered: 'K.f requires: was … now …' / 'K.f ensuring: removed (was …)'>\ncontracts are the human's — ask in chat before changing a require/ensuring/decreases; restore the original clause"`; then skip Stainless for this module. No snapshot file → `section note "vericoding: no contract snapshot for this session" "…cannot compare contracts; Stainless still runs"`. Launcher missing/call failed/no JSON reader → `section note "vericoding: contract guard stood down" "<reason>"`.
     - Stainless: `targets` = all registered kernel files of `$m` (kernels.tsv order, comma-joined); run `"$mill" --ticker false --color false "$m.stainlessVerify" --targets "$targets"` capturing output to a file and rc; add `$m.stainlessVerify` to `ran`. The script's marker lines decide the class (per Task 1's record): an invalid summary → `blocked+1`, `section blocking "vericoding: $m — Stainless found invalid verification conditions" "$(dsh_stainless_report …)\nFix the body so the contract holds; if the contract itself is wrong, stop and ask the human."`; setup failure (script exit 2 marker / no summary) → `section note "vericoding: Stainless could not run for $m" "<reason line>"`; unknown count > 0 → `section note "vericoding: $m — <N> verification condition(s) unknown (solver timeout)" "…"`.
  The existing verdict block then carries these like any other finding.

- [ ] **Step 5: GREEN** — `sh tests/run.sh` and `dash tests/run.sh` all pass (new cases included), `sh tests/lib-test.sh`, every `tests/*-test.sh`, `dash -n` on changed files.

- [ ] **Step 6: Commit** — `kit(harness): vericoding at turn-end — contracts snapshotted at SessionStart are the human's; Stainless verifies registered kernels` (+ trailer).

---

### Task 4: The `vericoding` skill, the installer, and the docs

**Files:**
- Create: `kit/skills/vericoding/SKILL.md`
- Modify: `Setup.scala` (`SkillNames` list, ~line 905: add `"vericoding"`)
- Modify: `kit/harness/README.md` (a "Vericoding" section: kernels.tsv, snapshot, the stage's block/note/stand-down table, the `contract_clauses` dependency, limits from the tool docs), `kit/apply.md` (a line under the harness step), `kit/digest.md` if it lists the skills (keep its list and `SkillNames` identical)

- [ ] **Step 1: Write the skill** — frontmatter `name: vericoding`, `description: Use when a task touches a file listed in .dsh/policy/kernels.tsv, or asks to implement a function whose require/ensuring is already written — fill the body until Stainless accepts it, never the contract.` Body sections: *When*; *The loop* (1 read the contracts: `contract_clauses` on the kernel file; 2 fill one body at a time — for `???` use `hole_context`; 3 run `./mill <module>.stainlessVerify --targets <the module's kernel files>`; 4 read each invalid VC and its counterexample, change the body, repeat; 5 an `unknown` VC is a solver timeout — simplify the body or ask; never add `assume`); *Never* (edit, weaken, delete or move a `require`/`ensuring`/`decreases`; unregister a kernel; add a local `require`/`ensuring` def); *When the contract looks wrong* (stop, quote the counterexample, ask the human); *What the gate does* (the turn-end block messages, verbatim headlines from Task 3).

- [ ] **Step 2: Installer** — add `"vericoding"` to `SkillNames` (and to the digest's list if it has one); `scala-cli compile Setup.scala --server=false` → no errors (run `scala-cli fmt Setup.scala` if the hook's fmt check rejects it).

- [ ] **Step 3: Docs** — engine README "Vericoding" section with the table (condition → block / note / stand-down, headline text) and the notes-table rows for the new notes; `apply.md` harness step gains: "to verify a kernel, follow recipe §8 and register the file in `.dsh/policy/kernels.tsv` (the human's)".

- [ ] **Step 4: Verify and commit** — `sh kit/harness/tests/run.sh` still green (README is engine content); commit `kit: the vericoding skill, installed with the kit; engine and recipe docs for kernels` (+ trailer).

---

## After the plan (not in it)

skreeep2 pilot (separate plan): re-vendor the engine, copy the recipe, write `core/src/.../PureKernels.scala` with the approved K1–K3, delegate the callers, register the row, run the live smoke (spec §4). Requires the human-installed `contract_clauses` launcher (`./mill installLocal --skip-clients` in ScalaSemanticMCP).

## Self-review notes

- Spec §1.2 → Task 1; §1.3 → Tasks 2–3; §1.4 → Task 4; §2 feasibility → Task 1 Steps 3–4 (human decides reformulations); §3 → Task 3 (guard, Stainless classes, attempt cap unchanged); §4 → fixtures (Task 3), real Stainless (Task 1), live smoke deferred to the pilot plan.
- Names consistent: `dsh_semantic_launcher`, `dsh_kernels_rows`, `dsh_kernel_of`, `dsh_kernel_checks`, `dsh_contracts_tsv`, `dsh_contract_file`, `dsh_contract_diff`, `dsh_stainless_report`, `StainlessModule.stainlessVerify(--targets)`, stub vars `SCALASEMANTIC_STUB_CONTRACTS_OUT`, `MILL_STUB_STAINLESS_OUT`, `MILL_STUB_STAINLESS_EXIT`.
- Known dependency: Task 3's parser patterns come from Task 1's measured record — Task 3 must read `kit/recipes/mill/stainless-feasibility.md` first.
