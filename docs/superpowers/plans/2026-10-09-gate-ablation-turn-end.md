# Gate Ablation (no turn-end arm) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third arm `t` (the gate minus the turn-end Stop hook) to `eval/gate-ab/`, run it 8 times, and report it against the existing gated and ungated runs.

**Architecture:** `t` is the gated arm with `hooks.Stop` deleted from the settings snapshot; every other part of the gated arm is unchanged. `campaign.sh` gets arm and task lists from the environment so the campaign runs `t` alone on 4 tasks. `report.py` adds an ablation section and a pre-registered verdict; the A/B section stays as it is.

**Tech Stack:** POSIX sh (`run.sh`, `campaign.sh`, `lib.sh`, tests in `tests/shell-test.sh`), Python 3 stdlib (`score.py`, `report.py`, tests with `unittest`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-08-gate-ablation-turn-end-design.md`

## Global Constraints

- Work on branch `gate-ablation` of scala-llm-template, from `master` (133d246).
- Arm `t` = the gated snapshot `$GA_ROOT/gated-settings.json` with the `Stop` hook entry removed; SessionStart, PreToolUse (tool-policy, semantic-guard), PostToolUse (post-edit), sandbox, `env.MILL_OUTPUT_DIR=out-agent` and precompile into `out-agent` stay.
- Tasks for the campaign: `backpressure mcu mixer-modes scope-view`; reps `1 2`; arm `t` only. 8 runs.
- Decision rule (spec §4), over 8 counted `t` runs: solved ≤ 5 → "turn-end carries the gain"; solved = 8 → "the gain comes without turn-end"; 6 or 7 → "unclear".
- Never modify skreeep2 or skreeep2-holdout. Never hand-edit skreeep2 `.dsh/engine/`.
- `git add` explicit paths only, never `git add -A` at the repo root.
- Commit messages end with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`. No `Co-Authored-By`.
- Test commands (run from `eval/gate-ab/`): `sh tests/shell-test.sh`; `python3 -m unittest -q tests/test_score.py tests/test_report.py tests/test_timeout.py`.

## Review Focus

1. A snapshot with no `hooks.Stop` given to arm `t` → `run.sh` dies before the agent starts (an arm `t` identical to `g` would silently measure nothing). Test in Task 1.
2. Arm `t`'s own hook events (PreToolUse, PostToolUse, SessionStart) → not reported as an env leak by `score.py` (Ruling 20 allows hooks only for `g` today). Test in Task 1.
3. `GA_ARMS` or `GA_TASKS` containing an unknown value → campaign dies before any run. Test in Task 2.
4. A runs dir with no `t` runs → `summary.md` has no ablation section and the A/B verdict is unchanged. Test in Task 3.
5. Fewer than 8 counted `t` runs (error or contamination) → ablation verdict "incomplete (n of 8)", never a band verdict. Test in Task 3.

---

### Task 1: Arm `t` in lib.sh, run.sh and score.py

**Files:**
- Modify: `eval/gate-ab/lib.sh` (`ga_run_id`)
- Modify: `eval/gate-ab/run.sh:5,19,40` (usage, arm branch, out dir)
- Modify: `eval/gate-ab/score.py` (`env_leaks`)
- Test: `eval/gate-ab/tests/shell-test.sh`, `eval/gate-ab/tests/test_score.py`

**Interfaces:**
- Produces: `ga_run_id <task> <g|u|t> <rep>`; `run.sh <task> <g|u|t> <rep>`; `score.env_leaks(t, arm)` allows hook events for arms `g` and `t`.

- [ ] **Step 1: Write the failing tests**

In `tests/shell-test.sh`, after the line `$SH -c ". '$ga/lib.sh'; ga_run_id noise g 0" ...` (line 16), add:

```sh
out=$($SH -c ". '$ga/lib.sh'; ga_run_id noise t 1")
check "run id arm t" "$out" "noise-t-1"
```

In `tests/shell-test.sh`, directly before the comment `# gated rewrite must verify itself: a contract without holdoutDir aborts before the agent starts`, add:

```sh
# Arm t: the gated snapshot without the Stop hook (gate ablation spec §3)
cp "$tmp/root/gated-settings.json" "$tmp/snap.keep"; cp "$tmp/root/gated-settings.json.sha256" "$tmp/snap.keep.sha256"
cat >"$tmp/root/gated-settings.json" <<EOF
{"sandbox":{"denyRead":"$tmp/hsrc/bin/check","denyWrite":"$tmp/hsrc"},"env":{"MILL_OUTPUT_DIR":"out-agent"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"tool-policy"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"turn-end"}]}]}}
EOF
python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/root/gated-settings.json" >"$tmp/root/gated-settings.json.sha256"
n0=$(grep -c '^out-agent --no-daemon ' "$tmp/mill.log")
runenv FAKE_ARGS=$tmp/args-tt.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-tt.txt FAKE_LS=$tmp/ls-tt.txt $SH "$tmp/home/run.sh" t1 t 1 >/dev/null 2>&1; check "run t exit 0" "$?" "0"
python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));h=s["hooks"];sys.exit(0 if "Stop" not in h and h["PreToolUse"] and s["env"]["MILL_OUTPUT_DIR"]=="out-agent" else 1)' "$rd/t1-t-1/repo/.claude/settings.json" \
  && ok "run t settings: no Stop, rest kept" || bad "run t settings: no Stop, rest kept" "$(cat "$rd/t1-t-1/repo/.claude/settings.json")"
hdt=$(CDPATH= cd -- "$rd/t1-t-1/holdout" && pwd -P)
grep -q "$hdt" "$rd/t1-t-1/repo/.claude/settings.json" && ! grep -q "$tmp/hsrc" "$rd/t1-t-1/repo/.claude/settings.json" && ok "run t holdout paths rewritten" || bad "run t holdout paths rewritten"
check "run t contract holdoutDir" "$(cat "$rd/t1-t-1/repo/.dsh/contract")" "holdoutDir = $hdt"
check "run t precompile into out-agent" "$(grep -c '^out-agent --no-daemon ' "$tmp/mill.log")" "$((n0 + 1))"
grep -q '"arm":"t"' "$rd/t1-t-1/run.json" && grep -q "\"gated_settings_sha256\":\"$(cat "$tmp/root/gated-settings.json.sha256")\"" "$rd/t1-t-1/run.json" \
  && ok "run t run.json arm and snapshot hash" || bad "run t run.json arm and snapshot hash" "$(cat "$rd/t1-t-1/run.json")"
cmp -s "$tmp/args-g.txt" "$tmp/args-tt.txt" && ok "agent command line identical in arm t" || bad "agent command line identical in arm t"
# a snapshot without a Stop hook would make t identical to g: die before the agent starts
cp "$tmp/snap.keep" "$tmp/root/gated-settings.json"; cp "$tmp/snap.keep.sha256" "$tmp/root/gated-settings.json.sha256"
rm -f "$tmp/ls-t2.txt"
runenv FAKE_ARGS=$tmp/args-t2.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-t2.txt FAKE_LS=$tmp/ls-t2.txt $SH "$tmp/home/run.sh" t1 t 2 >/dev/null 2>&1 \
  && bad "run t without Stop hook dies" || ok "run t without Stop hook dies"
[ ! -e "$tmp/ls-t2.txt" ] && ok "run t without Stop hook: agent not started" || bad "run t without Stop hook: agent not started"
```

(The original snapshot and its hash are restored before the negative case, so later tests see the snapshot they expect.)

In `tests/test_score.py`, after the test that asserts `score.env_leaks(t, "u") == ["hooks=PreToolUse:Bash"]` (line 156), add a test method in the same class, built the same way as that test's transcript `t`:

```python
    def test_arm_t_hooks_are_not_a_leak(self):
        # gate ablation: arm t runs the gate's hooks (minus Stop), so its hook events are expected
        t = score.parse_transcript([
            json.dumps({"type": "system", "subtype": "init", "mcp_servers": [{"name": "scala-semantic"}], "plugins": []}),
            json.dumps({"type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:Bash"}),
        ])
        self.assertEqual(score.env_leaks(t, "t"), [])
        self.assertEqual(score.env_leaks(t, "u"), ["hooks=PreToolUse:Bash"])
```

Before writing it, read lines 140–160 of `tests/test_score.py` and build the transcript exactly the way the neighbouring test does (event names and fields); keep the two assertions.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd eval/gate-ab && sh tests/shell-test.sh 2>&1 | grep -E 'FAIL|shell-test:'`
Expected: FAIL lines for `run id arm t`, `run t exit 0` and the other `run t` checks (`ga_run_id` rejects `t`).
Run: `python3 -m unittest -q tests/test_score.py`
Expected: FAIL in `test_arm_t_hooks_are_not_a_leak`.

- [ ] **Step 3: Implement**

`lib.sh`, in `ga_run_id`:

```sh
  case $2 in g|u|t) ;; *) ga_die "arm must be g, u or t, got $2" ;; esac
```

`run.sh` line 2 comment and usage: `run.sh <task> <g|u|t> <rep>`.

`run.sh`: replace `if [ "$arm" = g ]; then` with `if [ "$arm" != u ]; then`. Inside that branch, directly after the line `sed "s|$GA_HOLDOUT_SRC|$hd|g" "$snap" > "$rd/repo/.claude/settings.json"`, add:

```sh
  if [ "$arm" = t ]; then
    # gate ablation: arm t is the gated arm without the turn-end Stop hook; no Stop hook means t would equal g
    python3 -c 'import json,sys
p=sys.argv[1]; s=json.load(open(p)); h=s.get("hooks")
if not isinstance(h, dict) or "Stop" not in h: sys.exit("no hooks.Stop in the gated snapshot")
del h["Stop"]; json.dump(s, open(p, "w"), indent=2)' "$rd/repo/.claude/settings.json" || ga_die "arm t: cannot remove the Stop hook"
  fi
```

`run.sh` line 40: `[ "$arm" = u ] && pout=out || pout=out-agent`.

`score.py`, `env_leaks`: change the docstring's "hook events only in the gated arm" to "hook events only in the gated arms (g, and t: the gate without Stop)", and the condition to `if arm not in ("g", "t") and t.get("hook_events"):`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh tests/shell-test.sh 2>&1 | tail -1` — Expected: `shell-test: N passed, 0 failed`.
Run: `python3 -m unittest -q tests/test_score.py tests/test_report.py tests/test_timeout.py` — Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/lib.sh eval/gate-ab/run.sh eval/gate-ab/score.py eval/gate-ab/tests/shell-test.sh eval/gate-ab/tests/test_score.py
git commit -m "gate-ab: arm t — the gated snapshot without the turn-end Stop hook

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 2: campaign.sh arm and task lists (`GA_ARMS`, `GA_TASKS`)

**Files:**
- Modify: `eval/gate-ab/lib.sh:10` (`GA_TASKS`)
- Modify: `eval/gate-ab/campaign.sh` (rep/arm/task validation, main loop)
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Consumes: arm `t` accepted by `ga_run_id` (Task 1).
- Produces: `GA_ALL_TASKS` (the 8 task names, fixed); `GA_TASKS` (default `$GA_ALL_TASKS`, overridable); campaign env `GA_ARMS` (space-separated, default `g u`, each in `g u t`).

- [ ] **Step 1: Write the failing tests**

In `tests/shell-test.sh`, after the two `GA_REPS invalid` checks (after line 288), add:

```sh
# gate ablation: GA_ARMS and GA_TASKS
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_ARMS=t GA_REPS="1 2" GA_TASKS="backpressure mcu mixer-modes scope-view" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "ablation campaign: 8 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "8"
check "ablation campaign: order" "$(tr '\n' ' ' <"$tmp/calls")" "backpressure-t-1 mcu-t-1 mixer-modes-t-1 scope-view-t-1 backpressure-t-2 mcu-t-2 mixer-modes-t-2 scope-view-t-2 "
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_ARMS="g x" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_ARMS invalid arm dies" || ok "GA_ARMS invalid arm dies"
[ -s "$tmp/calls" ] && bad "GA_ARMS invalid: no runs" || ok "GA_ARMS invalid: no runs"
cenv GA_ARMS=" " $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_ARMS empty dies" || ok "GA_ARMS empty dies"
cenv GA_TASKS="mcu nosuch" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_TASKS unknown task dies" || ok "GA_TASKS unknown task dies"
[ -s "$tmp/calls" ] && bad "GA_TASKS invalid: no runs" || ok "GA_TASKS invalid: no runs"
cenv GA_TASKS=" " $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_TASKS empty dies" || ok "GA_TASKS empty dies"
```

Also add, near the existing `eight tasks` check (line 20), a check that the default is unchanged when `GA_TASKS` is unset:

```sh
out=$(env -u GA_TASKS $SH -c ". '$ga/lib.sh'; echo \$GA_TASKS")
check "default GA_TASKS is all tasks" "$out" "noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sh tests/shell-test.sh 2>&1 | grep -E 'FAIL|shell-test:'`
Expected: FAIL for `ablation campaign: 8 runs` (the campaign runs 16 g/u runs over all tasks) and the `GA_ARMS`/`GA_TASKS` invalid checks.

- [ ] **Step 3: Implement**

`lib.sh`, replace the `GA_TASKS=` line with:

```sh
GA_ALL_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"
GA_TASKS=${GA_TASKS:-$GA_ALL_TASKS}
```

`campaign.sh`, after the `GA_REPS` validation loop (the `for r in $reps; do case ...` line), add:

```sh
# Gate ablation: GA_ARMS (default "g u", each g, u or t) and GA_TASKS (default all 8, each a known task).
arms=${GA_ARMS:-g u}
[ -n "$(echo $arms)" ] || ga_die "GA_ARMS is empty"
for a in $arms; do case $a in g|u|t) ;; *) ga_die "GA_ARMS: invalid arm '$a' (want g, u or t)" ;; esac; done
[ -n "$(echo $GA_TASKS)" ] || ga_die "GA_TASKS is empty"
for t in $GA_TASKS; do case " $GA_ALL_TASKS " in *" $t "*) ;; *) ga_die "GA_TASKS: unknown task '$t'" ;; esac; done
```

Note `GA_ARMS=" "` must die: `${GA_ARMS:-g u}` keeps `" "` (set and non-empty), and `echo $arms` then prints nothing.

`campaign.sh`, main loop (last line): `for arm in g u` → `for arm in $arms`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh tests/shell-test.sh 2>&1 | tail -1` — Expected: `shell-test: N passed, 0 failed` (the existing `campaign 48 runs` / `GA_REPS=2: 16 runs` checks still pass: the defaults are unchanged).

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/lib.sh eval/gate-ab/campaign.sh eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: campaign GA_ARMS and GA_TASKS lists (gate ablation)

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 3: report.py ablation section and verdict

**Files:**
- Modify: `eval/gate-ab/report.py` (new constant, new function, new section at the end of `build_summary`)
- Test: `eval/gate-ab/tests/test_report.py`

**Interfaces:**
- Consumes: run records with `arm` in `g`, `u`, `t` (Task 1).
- Produces: `report.ablation_verdict(solved, n)` → one of `"turn-end carries the gain"`, `"the gain comes without turn-end"`, `"unclear"`, `"incomplete (%d of 8)"`; constants `ABLATION_RUNS = 8`, `ABLATION_RULE` (text).

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_report.py`, before any `if __name__` block:

```python
class AblationVerdict(unittest.TestCase):
    def test_bands(self):
        v = report.ablation_verdict
        self.assertEqual(v(0, 8), "turn-end carries the gain")
        self.assertEqual(v(5, 8), "turn-end carries the gain")
        self.assertEqual(v(6, 8), "unclear")
        self.assertEqual(v(7, 8), "unclear")
        self.assertEqual(v(8, 8), "the gain comes without turn-end")

    def test_incomplete(self):  # an excluded run must not let 7 runs fall into a band
        self.assertEqual(report.ablation_verdict(7, 7), "incomplete (7 of 8)")
        self.assertEqual(report.ablation_verdict(0, 0), "incomplete (0 of 8)")


class AblationSection(unittest.TestCase):
    def write(self, d, runs):
        for r in runs:
            os.makedirs(os.path.join(d, r["run_id"]))
            with open(os.path.join(d, r["run_id"], "score.json"), "w") as f:
                json.dump(r, f)
        report.main(d)
        with open(os.path.join(d, "summary.md")) as f:
            return f.read()

    def base(self):
        return [rec("a-g-1", "a", "g", 1, solved=True, wall_seconds=200), rec("a-u-1", "a", "u", 1, wall_seconds=50),
                rec("b-g-1", "b", "g", 1, solved=True), rec("b-u-1", "b", "u", 1, solved=True)]

    def test_no_t_runs_no_section(self):
        with tempfile.TemporaryDirectory() as d:
            s = self.write(d, self.base())
        self.assertNotIn("Ablation", s)
        self.assertIn("| metric | gated | ungated |", s)
        self.assertTrue(s.rstrip("\n").splitlines()[-1].startswith("false_done: gated"))  # A/B summary ends as before

    def test_section_restricted_to_t_tasks(self):
        t_runs = [rec("a-t-%d" % i, "a", "t", i, solved=(i <= 6), wall_seconds=60) for i in range(1, 9)]
        with tempfile.TemporaryDirectory() as d:
            s = self.write(d, self.base() + t_runs)
        self.assertIn("## Ablation: gate without turn-end (t)", s)
        self.assertIn("Tasks: a", s)
        self.assertIn("| n (headline) | 1 | 8 | 1 |", s)          # g, t, u over task a only (b excluded)
        self.assertIn("| solved | 1 | 6 | 0 |", s)
        self.assertIn("| median wall s | 200 | 60 | 50 |", s)
        self.assertIn("\nAblation verdict: unclear\n", s)
        self.assertIn("\nVerdict: ", s)                            # the A/B verdict is still there

    def test_contaminated_t_run_makes_incomplete(self):
        t_runs = [rec("a-t-%d" % i, "a", "t", i, solved=True) for i in range(1, 9)]
        t_runs[0]["contaminated"] = True
        with tempfile.TemporaryDirectory() as d:
            s = self.write(d, self.base() + t_runs)
        self.assertIn("\nAblation verdict: incomplete (7 of 8)\n", s)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `python3 -m unittest -q tests/test_report.py`
Expected: errors `AttributeError: module 'report' has no attribute 'ablation_verdict'` and failures in `test_section_restricted_to_t_tasks`.

- [ ] **Step 3: Implement**

In `report.py`, after `FALSE_DONE_MIN`:

```python
ABLATION_RUNS = 8  # gate ablation spec §4: 4 tasks x 2 reps of arm t
ABLATION_RULE = ("over %d counted runs of arm t (gate without the turn-end Stop hook): solved <= 5 -> turn-end carries the gain; "
                 "solved = 8 -> the gain comes without turn-end; 6 or 7 -> unclear; fewer than %d counted runs -> incomplete"
                 % (ABLATION_RUNS, ABLATION_RUNS))


def ablation_verdict(solved, n):
    if n != ABLATION_RUNS:
        return "incomplete (%d of %d)" % (n, ABLATION_RUNS)
    if solved <= 5:
        return "turn-end carries the gain"
    if solved == ABLATION_RUNS:
        return "the gain comes without turn-end"
    return "unclear"
```

In `build_summary`, the `arms` dict stays `("g", "u")` (the A/B tables are unchanged). Just before `return "\n".join(out)`, add:

```python
    t_runs = [r for r in runs if r.get("arm") == "t"]
    if t_runs:
        t_tasks = sorted(set(r.get("task") for r in t_runs))
        on = {a: [r for r in runs if r.get("arm") == a and r.get("task") in t_tasks] for a in ("g", "t", "u")}
        ab = {a: arm_stats(on[a]) for a in on}
        out += ["## Ablation: gate without turn-end (t)", "", "Tasks: " + ", ".join(t_tasks), "",
                "| metric | gated | no turn-end | ungated |", "|---|---|---|---|"]

        def arow(label, f):
            out.append("| %s | %s | %s | %s |" % (label, f(ab["g"]), f(ab["t"]), f(ab["u"])))
        arow("n (headline)", lambda s: s["n"])
        arow("solved", lambda s: s["solved"])
        arow("solve rate [Wilson 95%]", lambda s: "%.2f [%.2f, %.2f]" % ((s["solve_rate"],) + s["ci"]))
        arow("false_done", lambda s: s["false_done"])
        arow("timeouts (counted, unsolved)", lambda s: s["timeouts"])
        arow("contaminated (excluded)", lambda s: s["contaminated"])
        arow("error (excluded)", lambda s: s["errors"])
        arow("median wall s", lambda s: fmt(s["median_wall"], 0))
        arow("median cost USD", lambda s: fmt(s["median_cost"], 2))
        out += ["", "Ablation verdict: %s" % ablation_verdict(ab["t"]["solved"], ab["t"]["n"]), "",
                "Ablation rule: " + ABLATION_RULE, ""]
```

The A/B part ends with `""`, so the ablation heading follows a blank line.

- [ ] **Step 4: Run tests to verify they pass**

Run: `python3 -m unittest -q tests/test_report.py tests/test_score.py tests/test_timeout.py` — Expected: `OK`.
Run: `sh tests/shell-test.sh 2>&1 | tail -1` — Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/report.py eval/gate-ab/tests/test_report.py
git commit -m "gate-ab: report ablation section and pre-registered verdict for arm t

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 4 (controller, not a subagent): the campaign and the write-up

- [ ] **Step 1: Document** — add to `eval/gate-ab/README.md` a section "Gate ablation (arm t)" with the run command below and the §4 rule; commit with the same trailer.
- [ ] **Step 2: Run** — from scala-llm-template:
  `GA_ARMS=t GA_REPS="1 2" GA_TASKS="backpressure mcu mixer-modes scope-view" nohup sh eval/gate-ab/campaign.sh > ~/gate-eval/campaign-ablation.log 2>&1 &`
  with a watcher that stops the campaign on `"api_error_status":429` in any `*-t-*` transcript.
- [ ] **Step 3: Report** — `python3 eval/gate-ab/report.py ~/gate-eval/runs`; audit any contamination flag on `t` runs by hand (as Ruling 28); read the failing hidden tests of unsolved `t` runs.
- [ ] **Step 4: Write-up** — raw measurement file `raw/llm-scala-fusion/2026-10-09-local-gate-ablation-turn-end.md` and a roadmap item-1 update in scala-coding-guidelines; `check_evidence.py` clean; commit.
