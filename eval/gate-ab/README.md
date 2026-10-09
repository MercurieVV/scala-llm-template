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

Launch the smoke run and the campaign from a plain terminal (not inside a Claude Code session): run.sh unsets the
outer session's `CLAUDECODE` / `CLAUDE_CODE_*` variables before starting the agent, but a plain terminal is the
configuration the numbers are meant for.

### 3. Smoke test

```bash
sh eval/gate-ab/campaign.sh --smoke
```

Verify setup with a minimal run (useful for debugging before full campaign). Runs `midi-synth` arm g then u at rep 9 (kept out of the 1..3 scored set; report.py ignores rep 9). campaign.sh first unlocks run dirs, prepares any task whose `validation.txt` is not three `=yes` lines (smoke: only midi-synth), computes `head-baseline.json` if missing, snapshots `$GA_SKREEEP2/.claude/settings.json` once to `~/gate-eval/gated-settings.json` (+ `.sha256`) if absent, and re-execs itself under `caffeinate -dims`. Delete the snapshot to pick up a changed skreeep2 gate (only between campaigns).

### 4. Run the full campaign

```bash
sh eval/gate-ab/campaign.sh
```

`GA_REPS` (space-separated, default `"1 2 3"`, each 1..3, anything else aborts) limits the full campaign to those reps, e.g. `GA_REPS="2" sh eval/gate-ab/campaign.sh`; task/arm order is kept within each rep.

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
  settings.json        the arm's .claude/settings.json (gated: the snapshot, holdout path rewritten)
  precompile.log       the pre-agent compile (see below)
  transcript.jsonl     raw Claude conversation (one message per line)
  run.json             run_id, task, arm, rep, start/end epoch, exit_code, timed_out, precompile_seconds,
                       gated_settings_sha256 (null for u)
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

## Agent environment (both arms identical)

- `claude -p … --setting-sources project --strict-mcp-config --mcp-config .mcp.json`: no user/local settings, so none of
  the operator's plugins, hooks, MCP servers or `~/.claude/CLAUDE.md`; MCP = scala-semantic only. score.py checks the
  transcript's `system`/`init` event and records `error="agent environment leaked: …"` for any other MCP server, any
  non-built-in plugin (Claude Code's own `path: builtin` plugins load with any setting source), or (ungated) any hook
  event; a transcript with a result but no init event is `leaked: no init event`.
- Before the agent starts, run.sh removes `~/.claude/projects/<repo path, / and . as ->/` (auto-memory and transcripts of
  an earlier attempt of the same run id).
- Pre-agent compile (Ruling 19), outside wall time and before locking: `./mill __.compile + __.test.compile +
  __.semanticDbData + scalaSemanticWriteClasspath` in the run's repo into the arm's out dir (g: `out-agent`, u: `out`),
  cap `GA_PRECOMPILE_CAP` (1800 s), measured ~92 s cold. It gives the gate's semantic guard a SemanticDB index
  (`healthy=1`, 166/166 sources on midi-synth) and the MCP its classpath metadata (`.scala-semantic/classpath-mill.json`).
  A failure aborts the run before the agent starts.

## score.json notes

- Hidden score runs only the hidden spec's suite (`<TASK_MODULE>.testOnly <package>.<Object>`). The module's other suites, and every other test module, run in one `-k -j 1` Mill invocation (cap `GA_REGRESS_CAP`, default 1200 s) and count as regressions; failures are attributed per module from `[error] <module>.testForked` lines. Build breakage is an agent outcome, not an error: a module that no longer compiles is `<compile:<module>>`; a build definition that no longer compiles (`[error] build.mill:N` / `<dir>/package.mill:N`, `[error] compile Compilation failed`; Mill then fails every command, `resolve __.test` included) is `<build>`. A failure of the module listing (`resolve __:Module`, used only to attribute a failing regression run) for any other reason records `error="resolve __:Module failed: ..."`.
- `score_timeouts`: steps that hit the Mill cap during scoring (`<TASK_MODULE>`, `holdout.test`, `regressions`); a timeout counts as FAIL.
- `build_edits`: `*.mill` files the agent edited (suspects, reported only; not part of `solved`).
- `error`: `"scoring incomplete"` in a partial record (scoring died or still running); `"mill failed: ..."` for Mill failures without test output; `"hidden suite did not run"`; `"no baseline"`; `"agent api error: <status> <result text>"` when the agent's result event has `is_error=true` (usage limit, 429/5xx; not when the run timed out) — an infrastructure failure, so `campaign.sh` reruns the whole run.
- Contamination detection is token-based: it resolves path-like tokens against `<run>/repo` and does not follow `cd` chains, variables or subshells, so a multi-`cd` command can evade it. It is a tripwire, not a sandbox (run.sh's mode-000 locking is the enforcement).
  Protected: `base/`, `head/`, other run dirs, the skreeep2 repo, `~/.claude/projects` (the run's own project dir excepted),
  and inside the run dir `holdout/`, `repo/out-holdout`, `repo/.dsh/.state/holdout.log`. Any ancestor of an outside
  protected path is flagged too (`find / …`, `grep -r … ~`, Glob `path: "/"`). Roots `/`, `~`, `$HOME`, `${HOME}`,
  `~user` resolve; a bare `/` counts only as an unquoted argument of a walker (find, grep, rg, ls, cat, du, …) in its own
  pipeline segment. Here-document bodies redirected into a file (`cat > A.scala <<'EOF'`, `>>`, `tee`) are not scanned;
  script here-docs (`python3 - <<EOF`, `sh <<EOF`) are. Tokens starting `//` or `/*` are ignored, a glob token stands for
  its literal directory prefix (`/a/b/*.scala` → `/a/b`), and Grep's `pattern` is a regex, never a path.

## Crash recovery

While an agent runs, run.sh makes `~/gate-eval/base`, `~/gate-eval/head` and the other run dirs mode 000 (agent isolation) and restores them on exit, including on INT/TERM. After a hard crash (kill -9, power loss) they may stay locked: run `. eval/gate-ab/lib.sh; ga_unlock_all` (campaign.sh does this at start).

## Testing

```bash
# Test under sh
sh eval/gate-ab/tests/shell-test.sh

# Test under dash
SH=dash dash eval/gate-ab/tests/shell-test.sh
```

Expected: 106 passed, 0 failed (both shells). Python: `python3 -m unittest discover -s eval/gate-ab/tests -p 'test_*.py'` → 154 tests OK (~100 s; the fake-Mill tests sleep).

## Preparing the cache and tasks

`sh warm-cache.sh` once (builds the HEAD reference tree, about 1 min), then `sh prepare.sh <task>` per task (about 1 min each; `noise` takes about 11 min because its hidden spec hangs on the stub, see below). Mill selectors used: `__.compile` and `__.test.compile` (both valid in skreeep2 at 6bf6c1b).

- Mill records absolute paths in its output, so an `out` directory is never copied: a copy writes into the original's classes and would leak one run's compiled solution into the next. warm-cache.sh only builds the HEAD reference tree `~/gate-eval/head` (its own `out`); every other tree compiles cold, about 53 s.
- Test-running Mill calls in prepare.sh are capped at 600 s; a timeout counts as FAIL. On the `noise` cut tree `???` in an object initialiser deadlocks weaver, so `hidden_fails_on_cut=yes` there comes from the cap.

## Smoke run

2026-10-03 (re-run after the final-review fixes), `sh campaign.sh --smoke`, model sonnet, midi-synth rep 9:

| run | precompile | wall | turns | cost USD | solved | hidden_pass_ratio | gate_blocks | contamination | error |
|---|---|---|---|---|---|---|---|---|---|
| midi-synth-g-9 | 86 s | 159 s | 14 | 0.189 | true | 1.0 | semantic-guard 2, turn-end 1 | none | none |
| midi-synth-u-9 | 88 s | 34 s | 10 | 0.098 | true | 1.0 | none | none | none |

Init events (both arms): MCP servers = scala-semantic only (`source: dynamic`), plugins = Claude Code's three
built-ins only (`path: builtin`), 17 built-in skills, no user skills. Ungated: no hook event at all. Gated: SessionStart
reports "semantic guard is active … an index is present at …/out-agent/…" (it stood down on the cold tree before the
fix); the agent's scala-semantic calls (`find_usages`, `annotated_source` read and write) answered from the index, and
the guard blocked one text Edit and one Bash on a .scala path. Holdout passed, no regressions, both runs solved.

The first smoke (before the fix: 195 s / 60 s, both solved) ran with the operator's user plugins, hooks and MCP servers
in both arms and the semantic guard down; its numbers are superseded.

## Gate ablation (arm t)

Arm `t` is the gated arm without the turn-end Stop hook: `run.sh` copies the campaign's gated snapshot and deletes
`hooks.Stop` (it dies if the snapshot has none); every other hook, the sandbox and `out-agent` stay. Spec:
`docs/superpowers/specs/2026-10-08-gate-ablation-turn-end-design.md` in scala-coding-guidelines.

```sh
GA_ARMS=t GA_REPS="1 2" GA_TASKS="backpressure mcu mixer-modes scope-view" sh eval/gate-ab/campaign.sh
python3 eval/gate-ab/report.py ~/gate-eval/runs
```

`campaign.sh` reads `GA_ARMS` (default `g u`, each `g`, `u` or `t`) and `GA_TASKS` (default all eight tasks).
`summary.md` gets an "Ablation" section comparing g, t and u on the tasks `t` ran, with the pre-registered verdict:
over 8 counted `t` runs, solved ≤ 5 → "turn-end carries the gain"; 8 → "the gain comes without turn-end"; 6 or 7 →
"unclear"; fewer than 8 counted → "incomplete".

The verdict is printed twice: strict (contaminated runs excluded) and audited. For the audited one, list the ids of runs
whose contamination flag you reviewed and found to be a false positive, one per line, in `<runs-root>/audit-cleared.txt`
(`#` comments and blank lines ignored). A listed run counts if it has no `error`; errors are never cleared. Without the
file, only the strict verdict is shown.

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

The test root links `base` and `head` from `$R`; its `u` runs are the fresh ungated runs (screen runs are not
counted, they were selected for failing).
