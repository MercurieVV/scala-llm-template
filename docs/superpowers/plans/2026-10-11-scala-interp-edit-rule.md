# Scala Interpreter-Edit Rule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deny Bash commands that edit Scala source through an interpreter or `sed -i`, and measure the rule alone (arm `p`) against ungated (`u`) on the two feature tasks where the silent no-op edit appeared.

**Architecture:** One new verdict in `kit/harness/hooks/tool-policy.sh`, hooked at the point where the hook already classifies a segment as an interpreter (`_it_interp`), plus a separate `sed` in-place flag. The eval harness gains arm `p`: engine installed, settings reduced to the PreToolUse tool-policy hook only.

**Tech Stack:** POSIX sh (engine, harness), python3 (settings filter, scorer), Claude Code headless.

**Spec:** /Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-11-scala-interp-edit-rule-design.md

## Global Constraints

- Budget: at most 16 agent runs.
- Rule is always on; no policy row. The frozen-path verdict keeps precedence (it runs first).
- A path token counts only when it ends `.scala` or `.sc` followed by a non-path character or end of text (`.scalafmt.conf`, `.scala-build/` do not count).
- Never modify skreeep2 or skreeep2-holdout; never stage skreeep2 files.
- Commits end with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`; no Co-Authored-By. Explicit `git add` paths.
- Run root `~/gate-eval-interp/`; older run roots `chmod 000` during the campaign and restored to 755 after.
- Decision rule (n = 8 per arm): `u` false_done − `p` false_done ≥ 2 → "the rule pays"; ≤ 0 → "no gain"; else "unclear"; `u` false_done 0 → "failure not reproduced".

## Review Focus

- A `sed` expression containing the letter `i` (`sed -e 's/i/x/' A.scala`, `sed -n '/if/p' A.scala`): must stay allowed — only an OPTION word carries the in-place flag. Test: `scala-interp-sed-expr-with-i-allowed` (Task 1).
- A frozen Scala file named by a python write: the frozen verdict must still be the one reported (its message names the freeze). Test: existing `frozen-interp-python-heredoc-denied` keeps passing; the new check runs after it.
- A python command whose text mentions `.scala` only inside a longer token (`foo.scalaX`, `.scala-build/x`): allowed. Test: `scala-interp-scala-build-dir-allowed` (Task 1).
- Arm `p`'s settings must contain no sandbox, no Stop, no SessionStart, no semantic-guard entry — otherwise `p` is not "the rule alone". Test: `ga_policy_only_settings` shell test (Task 2).
- `env_leaks` must accept hook events in arm `p` and still flag them in `u`. Test: `test_arm_p_hooks_are_not_a_leak` (Task 2).

---

### Task 1: The rule in tool-policy

**Files:**
- Modify: `kit/harness/hooks/tool-policy.sh` (interpreter detection block ~line 984–1038; new functions after `check_frozen_interp_text`, ~line 302)
- Create: `kit/harness/tests/cases/scala-interp-*/` (payload.json, subcommand, expect.code, expect.grep where denied)
- Modify: `kit/harness/README.md` (tool-policy section: one paragraph)

**Interfaces:**
- Produces: denial text containing `editing Scala source through an interpreter or sed can fail silently` (Task 3 counts blocks by this string).

- [ ] **Step 1: Write the failing cases**

Each case dir has `subcommand` = `tool-policy`, `payload.json` = `{"tool_name":"bash","tool_input":{"command":"<cmd>"}}`. Denied cases: `expect.code` = `2`, `expect.grep` = `editing Scala source through an interpreter or sed can fail silently`. Allowed cases: `expect.code` = `0`, no expect.grep.

| case | command | code |
|---|---|---|
| scala-interp-python-heredoc-denied | `python3 - <<'EOF'\np='control/src/MixerMode.scala'\ns=open(p).read().replace('        case', '      case')\nopen(p,'w').write(s)\nEOF` | 2 |
| scala-interp-python-c-denied | `python3 -c "open('a/A.scala','w').write('x')"` | 2 |
| scala-interp-sed-i-denied | `sed -i 's/a/b/' a/Foo.scala` | 2 |
| scala-interp-sed-i-bak-denied | `sed -i.bak 's/a/b/' a/Foo.scala` | 2 |
| scala-interp-sed-cluster-denied | `sed -Ei 's/a/b/' a/Foo.scala` | 2 |
| scala-interp-sed-long-denied | `sed --in-place 's/a/b/' a/Foo.scala` | 2 |
| scala-interp-perl-pi-sc-denied | `perl -pi -e 's/a/b/' a/build.sc` | 2 |
| scala-interp-bash-c-denied | `bash -c "cat x > a/Foo.scala"` | 2 |
| scala-interp-python-plain-allowed | `python3 -c 'print(1)'` | 0 |
| scala-interp-sed-read-allowed | `sed -n 1,5p a/Foo.scala` | 0 |
| scala-interp-sed-expr-with-i-allowed | `sed -e 's/i/x/' a/Foo.scala` | 0 |
| scala-interp-cat-allowed | `cat a/Foo.scala` | 0 |
| scala-interp-scalafmt-conf-allowed | `python3 tool.py .scalafmt.conf` | 0 |
| scala-interp-scala-build-dir-allowed | `python3 -c "import os;os.listdir('.scala-build/x')"` | 0 |
| scala-interp-grep-allowed | `grep -n foo a/Bar.scala` | 0 |

Write them with a short python generator run once from the repo root (JSON escaping of `\n` handled by `json.dumps`).

- [ ] **Step 2: Run them, watch the denied ones fail**

Run: `RUN_CASES='scala-interp-*' sh kit/harness/tests/run.sh 2>&1 | tail -20`
Expected: the 8 `*-denied` cases FAIL (exit 0, no message); the 7 `*-allowed` cases pass.

- [ ] **Step 3: Implement**

After `check_frozen_interp_text`'s closing brace add:

```sh
# The Scala-source edit verdict (spec 2026-10-11). An interpreter or `sed -i` that edits a .scala/.sc
# file through text replacement fails SILENTLY when its search text does not match: nothing changes,
# everything still compiles, and the agent reports done (measured: 3 of 8 ungated screen runs on the
# feature-request study, 2026-10-10). The Edit tool refuses a non-matching edit, so the same mistake
# is loud there. Text, not semantics: fires when the WHOLE command text names a .scala/.sc path token.
deny_scala_interp() { # <path token>
  printf 'BLOCKED by tool-policy: %s is Scala source.\n' "$(bound_bytes "${1:-}" 240)" >&2
  cat >&2 <<'MSG'
Editing Scala source through an interpreter or sed can fail silently — a replace that matches
nothing changes nothing and raises no error, and the code still compiles.
Use the Edit tool (it refuses an edit whose text is not found), or the MCP write path the semantic
guard names where that guard is active. Use Read or Grep to read.
NOT covered: a file name the program computes at run time, and an interpreter run from a script file.
MSG
  exit 2
}

check_scala_interp_text() {
  # One token per line: split $cmd on every character that cannot be part of a bare path word.
  _si_hit=$(printf '%s\n' "$cmd" | tr -c 'A-Za-z0-9._/~+-' '\n' | grep -E '\.(scala|sc)$' | head -1) || :
  [ -n "$_si_hit" ] && deny_scala_interp "$_si_hit"
  return 0
}
```

In the per-segment block, set `_it_sedi` next to `_it_interp=0` and add a `sed|gsed)` arm to `case "$_it_word" in`:

```sh
    _it_interp=0
    _it_sedi=0
    case "$_it_word" in
      sed|gsed)
        for _it_a in "$@"; do
          case "$_it_a" in
            --in-place*) _it_sedi=1; break ;;
            --*) ;;
            -i*|-[!-]*i*) _it_sedi=1; break ;;
          esac
        done ;;
```

(Existing `sh|bash|zsh|dash)`, `awk|…)`, `*)` arms unchanged.) Replace the line `[ "$_it_interp" = 1 ] && check_frozen_interp_text` with:

```sh
    [ "$_it_interp" = 1 ] && check_frozen_interp_text
    { [ "$_it_interp" = 1 ] || [ "$_it_sedi" = 1 ]; } && check_scala_interp_text
```

Note `-[!-]*i*` matches `-Ei`, `-ni`; a sed SCRIPT word (`s/i/x/`) does not start with `-`, so it never matches; `-e` is followed by the script as a separate word.

- [ ] **Step 4: Run the new cases, then the whole engine suite**

Run: `RUN_CASES='scala-interp-*' sh kit/harness/tests/run.sh 2>&1 | tail -5`
Expected: 15 passed, 0 failed.
Run: `sh kit/harness/tests/run.sh > /tmp/engine-cases.log 2>&1; tail -3 /tmp/engine-cases.log`
Expected: 0 failed. If a pre-existing case now fails, read it: an allowed case that names a `.scala` file through python or `sed -i` is now correctly denied only if the spec says so — e.g. `semantic-guard-bash-interpreter-read-allowed` runs subcommand semantic-guard, not tool-policy, so it is unaffected; any tool-policy case that changes verdict is a ruling (ledger it).

- [ ] **Step 5: README paragraph**

In `kit/harness/README.md`, in the tool-policy section, add: "Scala source through an interpreter or sed (2026-10-11): a Bash command that runs an interpreter or inline shell, or `sed` in place, and whose text names a `.scala`/`.sc` path, is denied — a text replace that matches nothing changes nothing silently; the Edit tool refuses it loudly. Always on; the frozen-path verdict runs first."

- [ ] **Step 6: Commit**

```bash
git add kit/harness/hooks/tool-policy.sh kit/harness/README.md kit/harness/tests/cases/scala-interp-*
git commit -m "tool-policy: deny Scala source edits through an interpreter or sed -i"
```

### Task 2: Arm `p` in the eval harness

**Files:**
- Modify: `eval/gate-ab/lib.sh:35-36` (ga_run_id), add `ga_policy_only_settings`
- Modify: `eval/gate-ab/campaign.sh:44`
- Modify: `eval/gate-ab/run.sh:2,5,29-36`
- Modify: `eval/gate-ab/score.py:152` (env_leaks)
- Test: `eval/gate-ab/tests/shell-test.sh`, `eval/gate-ab/tests/test_score.py`

**Interfaces:**
- Consumes: `ga_install_engine <repo> <full|safety>` (exists).
- Produces: `ga_policy_only_settings <settings.json>` — rewrites the file in place: keeps only `hooks.PreToolUse` entries whose command contains `gate.sh" tool-policy`, drops every other hook event, drops `sandbox`; exits non-zero if no such entry. Arm string `p`.

- [ ] **Step 1: Failing tests**

shell-test.sh, beside the gf tests:

```sh
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan p 1")
check "run id arm p" "$out" "fr-pan-p-1"
GA_ROOT=$(mktemp -d) GA_CAFFEINATED=1 GA_ARMS="p x" $SH "$ga/campaign.sh" >/dev/null 2>&1; check "campaign rejects arm x beside p" "$?" "1"
pf=$(mktemp)
cat > "$pf" <<'J'
{"env":{"MILL_OUTPUT_DIR":"out-agent"},"sandbox":{"enabled":true},"permissions":{"deny":["Read(./holdout/**)"]},
 "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" baseline"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" tool-policy","timeout":30}]},
   {"matcher":"Read|Bash","hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" semantic-guard"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" turn-end"}]}]}}
J
$SH -c ". '$ga/lib.sh'; ga_policy_only_settings '$pf'"
out=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));h=s["hooks"];print(sorted(h), len(h["PreToolUse"]), "tool-policy" in h["PreToolUse"][0]["hooks"][0]["command"], "sandbox" in s, s["env"]["MILL_OUTPUT_DIR"], s["permissions"]["deny"][0])' "$pf")
check "policy-only settings keep only tool-policy" "$out" "['PreToolUse'] 1 True False out-agent Read(./holdout/**)"
printf '{"hooks":{"Stop":[]}}' > "$pf"
$SH -c ". '$ga/lib.sh'; ga_policy_only_settings '$pf'" >/dev/null 2>&1; check "policy-only settings refuse a snapshot without tool-policy" "$?" "1"
```

test_score.py, class `EnvLeak`:

```python
    def test_arm_p_hooks_are_not_a_leak(self):
        hook = json.dumps({"type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:Bash", "hook_event": "PreToolUse"})
        t = score.parse_transcript(lines("real-init-isolated.jsonl") + [hook])
        self.assertEqual(score.env_leaks(t, "p"), [])
        self.assertEqual(score.env_leaks(t, "u"), ["hooks=PreToolUse:Bash"])
```

- [ ] **Step 2: Run, watch them fail**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | grep -E "FAIL|passed"` and `cd eval/gate-ab/tests && python3 -m unittest test_score.EnvLeak.test_arm_p_hooks_are_not_a_leak`
Expected: the 4 new shell checks FAIL ("arm must be …", function not found); the python test FAILS with `['hooks=PreToolUse:Bash'] != []`.

- [ ] **Step 3: Implement**

lib.sh:

```sh
ga_run_id() {
  case $2 in g|u|t|gf|gs|p) ;; *) ga_die "arm must be g, u, t, gf, gs or p, got $2" ;; esac
```

(rest of ga_run_id unchanged), and after `ga_install_engine`:

```sh
# Arm p (spec 2026-10-11): the tool-policy hook alone — no sandbox, no other hook event, no other PreToolUse entry.
ga_policy_only_settings() {  # <settings.json>, rewritten in place
  python3 - "$1" <<'PY' || ga_die "arm p: no tool-policy PreToolUse entry in $1"
import json, sys
p = sys.argv[1]; s = json.load(open(p))
pre = [e for e in (s.get("hooks") or {}).get("PreToolUse", [])
       if any('gate.sh" tool-policy' in h.get("command", "") for h in e.get("hooks", []))]
if not pre: sys.exit(1)
s["hooks"] = {"PreToolUse": pre}; s.pop("sandbox", None)
json.dump(s, open(p, "w"), indent=2)
PY
}
```

campaign.sh:44 → `case $a in g|u|t|gf|gs|p) ;; *) ga_die "GA_ARMS: invalid arm '$a' (want g, u, t, gf, gs or p)" ;; esac`

run.sh: usage strings `<g|u|t|gf|gs|p>`; the engine-install line becomes

```sh
  case $arm in gf) ga_install_engine "$rd/repo" full ;; gs) ga_install_engine "$rd/repo" safety ;;
    p) ga_install_engine "$rd/repo" safety; ga_policy_only_settings "$rd/repo/.claude/settings.json" ;; esac
```

score.py:152 → `if arm not in ("g", "t", "gf", "gs", "p") and t.get("hook_events"):` and the docstring's arm list gains `p`.

- [ ] **Step 4: Run both suites**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1` → `shell-test: 170 passed, 0 failed`
Run: `cd eval/gate-ab/tests && python3 -m unittest discover -s . -p 'test_*.py' 2>&1 | tail -2` → `OK` (182 tests)

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/lib.sh eval/gate-ab/campaign.sh eval/gate-ab/run.sh eval/gate-ab/score.py eval/gate-ab/tests/shell-test.sh eval/gate-ab/tests/test_score.py
git commit -m "gate-ab: arm p — the tool-policy hook alone"
```

### Task 3: Campaign (16 runs)

**Files:** run root `~/gate-eval-interp/` only.

- [ ] **Step 1: Run root.** `mkdir ~/gate-eval-interp && cp -R ~/gate-eval-feature/head ~/gate-eval-feature/head-baseline.json ~/gate-eval-feature/gated-settings.json ~/gate-eval-interp/` (plus `gated-settings.json.sha256` if present). Write `~/gate-eval-interp/RULE.md` with the Global Constraints' decision rule verbatim, before any run.
- [ ] **Step 2: Prepare.** `GA_ROOT=~/gate-eval-interp GA_TASKS="fr-pan fr-exclusive-solo" sh eval/gate-ab/prepare.sh` per task as campaign.sh does (campaign prepares missing bases itself). Expected: `validation.txt` 4 lines all `=yes` per task.
- [ ] **Step 3: Smoke.** In one `p` run tree (after it is built), the agent's `settings.json` has only `PreToolUse` with the tool-policy entry and no `sandbox`; `.dsh/engine/hooks/tool-policy.sh` contains `check_scala_interp_text`.
- [ ] **Step 4: Campaign**, in background:

```sh
chmod 000 ~/gate-eval ~/gate-eval-hard ~/gate-eval-control ~/gate-eval-feature; GA_ROOT=~/gate-eval-interp GA_TASKS="fr-pan fr-exclusive-solo" GA_ARMS="p u" GA_REPS="1 2 3 4" sh eval/gate-ab/campaign.sh > ~/gate-eval-interp/campaign.out 2>&1; chmod 755 ~/gate-eval ~/gate-eval-hard ~/gate-eval-control ~/gate-eval-feature
```

Expected: 16 runs, `error` null in every `score.json`.

- [ ] **Step 5: Tabulate and audit.** Per arm: solved, false_done, regression_count, median wall and cost; per `p` run the count of tool results containing `editing Scala source through an interpreter or sed can fail silently`; per run whether the agent wrote a script file and ran it to edit Scala (route-around); per false_done run, confirm from `final.diff` whether the requested behaviour is missing (silent no-op). Clear or keep contamination/tamper flags with reasons. Apply the decision rule.

### Task 4: Wiki write-up (scala-coding-guidelines, karpathy-llm-wiki skill)

- [ ] **Step 1:** Raw file `raw/llm-scala-fusion/2026-10-11-local-scala-interp-edit-rule.md` (format of `2026-10-10-local-gate-feature-requests.md`): rule, cases, campaign table, decision, audit. Include the correction: in the 2026-10-10 study the gated "Edit tool in 7 of 8" counted Edit tool CALLS, including calls the semantic guard blocked (it routes `.scala` writes to the MCP `annotated_source` write path).
- [ ] **Step 2:** Roadmap: item 12 gets `> **Status: Not pursued** (2026-10-11) — …` (item 11 found no regressions); item 11's block gets the rule and its result; item 13 noted as not triggered. Index row and log entry.
- [ ] **Step 3:** `python3 ~/.claude/skills/karpathy-llm-wiki/scripts/check_evidence.py . wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md` → 0 suspects; commit by explicit paths.
