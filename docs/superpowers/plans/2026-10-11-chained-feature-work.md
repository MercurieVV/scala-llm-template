# Chained Feature Work Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run item 11's four feature requests as one chain on the same tree (u vs gs, 2 chains each), scoring each step on its own hidden spec, on every earlier step's hidden spec, and on an erosion figure.

**Architecture:** `run.sh` learns to start from the previous step's final tree (`GA_SEED_TREE`); `campaign.sh` gets a chain mode (`GA_CHAIN`) that orders the steps, passes seeds, redoes a chain's later steps when an earlier one re-ran, and calls `chaincheck.py` after each step. `chaincheck.py` re-runs earlier hidden specs on the step's tree and calls `erosion.py`, which lists changed main files and asks `erosion.scala` (scala-cli + scalameta) for per-method CC and SLOC. `prepare-chain.sh` validates the chain on HEAD + reference patches and records the reference erosion line; `chain_report.py` prints the table and the pre-registered verdicts.

**Tech Stack:** POSIX sh (must run under sh and dash), Python 3 stdlib + unittest, scala-cli 1.15 with Scala 3.8.4 and scalameta 4.17.3, Mill (skreeep2's `./mill`).

**Spec:** `/Users/viktorskalinins/IdeaProjects/my/scala-coding-guidelines/docs/superpowers/specs/2026-10-11-chained-feature-work-design.md`

## Global Constraints

- Chain order: fr-pan → fr-exclusive-solo → fr-mode-leds → fr-tuning; item 11's prompts, hidden specs and reference patches unchanged.
- Arms `u` and `gs`, 2 chains each: 16 runs, same day, run root `~/gate-eval-chain/`. Model sonnet; cap and flags as item 11.
- Each step is a fresh headless `claude -p` session; a failed step does not stop the chain.
- Chain regression: (k, j) fails where step j's own spec had passed at the end of step j; otherwise `na`.
- Erosion: main (non-test) `.scala` files changed vs skreeep2 6bf6c1b; CC = 1 + one per `if`, `case`, `while`, `for` guard, `&&`, `||` (catch cases are `case`s); SLOC = non-blank, non-comment lines; mass = CC × √SLOC; erosion = share of mass in methods with CC > 10.
- Decision rules (spec §4) are fixed: gate u − gs ≥ 2 "gate pays on chains", ≤ 0 "no gain", else "unclear"; item 15 if any false_done route not blocked by the interpreter rule; item 16 if erosion rises step 1 → 4 in ≥ 3 of 4 chains and ends above the reference step 4.
- Existing behaviour unchanged when `GA_SEED_TREE` / `GA_CHAIN` are unset; existing suites stay green (`sh eval/gate-ab/tests/shell-test.sh`, `python3 -m unittest discover -s eval/gate-ab/tests`).
- Never modify skreeep2 or skreeep2-holdout (read-only). Commits end with `Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw`; no Co-Authored-By. Explicit `git add` paths.

## Deviations from the spec (rulings made while planning)

- Spec §3 names `chain.sh <u|gs> <rep>`; the chain loop lives in `campaign.sh` as `GA_CHAIN` mode instead, to reuse its preflight, resume and retry logic. Cost if wrong: one thin wrapper script.
- Spec §3 names `report.py`; the chain table is a new `chain_report.py`, leaving `report.py`'s arm checks (which reject non g/u/t arms) alone. Cost if wrong: a merge of two small files.
- `ga_install_engine` commits with `--allow-empty`, because a seeded `gs` tree already carries the identical engine and the commit would otherwise fail.

## Review Focus

1. A seeded tree that still carries the previous step's `.git`, `base` tag or `.claude/settings.json` — expected: fresh repository, one `base` commit, settings rewritten per arm (Task 2 tests).
2. A campaign resumed after step k was re-run — expected: steps k+1..4 of that chain are redone, the other chain untouched (Task 4 test).
3. An earlier spec that no longer compiles on the step's tree — expected: status `fail`, not a crash, and the next earlier spec still checked (Task 3 test).
4. Erosion on a tree with no changed main files — expected: `{"methods": 0, "total_mass": 0.0, "erosion": 0.0}` without calling scala-cli (Task 1 test).
5. A reference patch that conflicts in the chain order — expected: `patches_apply=no`, non-zero exit, campaign refuses to start (Task 5 test).

---

### Task 1: Erosion figure

**Files:**
- Create: `eval/gate-ab/erosion.scala`
- Create: `eval/gate-ab/erosion.py`
- Create: `eval/gate-ab/tests/fixtures/erosion/F.scala`
- Test: `eval/gate-ab/tests/test_erosion.py`

**Interfaces:**
- Produces: `erosion.changed_main_files(tree: str, head: str) -> list[str]` (absolute paths, sorted); `erosion.aggregate(methods: list[dict]) -> dict` with keys `methods` (int), `total_mass` (float, 3 dp), `erosion` (float, 4 dp); `erosion.measure(tree: str, head: str) -> dict` (same keys); `erosion.ErosionError(Exception)`. CLI: `python3 erosion.py <tree> <head>` prints the `measure` dict as JSON. Env `GA_SCALA_CLI` (default `scala-cli`).
- `erosion.scala` CLI: `scala-cli run -q erosion.scala -- <file>...` prints one JSON object `{"methods":[{"file":..,"name":..,"line":..,"cc":..,"sloc":..}, ...]}`.

- [ ] **Step 1: Write the fixture and the failing tests**

`eval/gate-ab/tests/fixtures/erosion/F.scala`:

```scala
object F:
  def small(x: Int): Int =
    if x > 0 && x < 5 then 1
    else x match
      case 1 => 2
      case _ => 3

  def big(x: Int): Int =
    if x == 1 then 1
    else if x == 2 then 2
    else if x == 3 then 3
    else if x == 4 then 4
    else if x == 5 then 5
    else if x == 6 then 6
    else if x == 7 then 7
    else if x == 8 then 8
    else if x == 9 then 9
    else if x == 10 then 10
    else if x == 11 then 11
    else 0

  def outer(x: Int): Int =
    // a comment line is not SLOC
    def inner(y: Int): Int = if y > 0 then y else 0
    inner(x)
```

`eval/gate-ab/tests/test_erosion.py`:

```python
import json, math, os, shutil, subprocess, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import erosion

FIX = os.path.join(HERE, "fixtures", "erosion", "F.scala")


class Aggregate(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(erosion.aggregate([]), {"methods": 0, "total_mass": 0.0, "erosion": 0.0})

    def test_share_of_mass_above_cc_10(self):
        ms = [dict(cc=12, sloc=4), dict(cc=2, sloc=9)]
        big, small = 12 * 2.0, 2 * 3.0
        r = erosion.aggregate(ms)
        self.assertEqual(r["methods"], 2)
        self.assertEqual(r["total_mass"], round(big + small, 3))
        self.assertEqual(r["erosion"], round(big / (big + small), 4))

    def test_cc_exactly_10_is_not_eroded(self):
        self.assertEqual(erosion.aggregate([dict(cc=10, sloc=1)])["erosion"], 0.0)


class ChangedFiles(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.head, self.tree = os.path.join(self.d, "head"), os.path.join(self.d, "tree")
        for root in (self.head, self.tree):
            for rel in ("m/src/A.scala", "m/src/B.scala", "m/test/src/ASpec.scala", ".dsh/x/C.scala", "out/m/D.scala"):
                p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
                open(p, "w").write("object X\n")

    def tearDown(self):
        shutil.rmtree(self.d)

    def test_only_changed_or_new_main_files(self):
        open(os.path.join(self.tree, "m/src/A.scala"), "w").write("object Changed\n")
        open(os.path.join(self.tree, "m/src/New.scala"), "w").write("object New\n")
        for rel in ("m/test/src/ASpec.scala", ".dsh/x/C.scala", "out/m/D.scala"):
            open(os.path.join(self.tree, rel), "w").write("object Changed\n")
        os.makedirs(os.path.join(self.tree, "out-agent/m")); open(os.path.join(self.tree, "out-agent/m/E.scala"), "w").write("x")
        got = [os.path.relpath(p, self.tree) for p in erosion.changed_main_files(self.tree, self.head)]
        self.assertEqual(got, ["m/src/A.scala", "m/src/New.scala"])

    def test_no_changes_measures_zero_without_scala_cli(self):
        with mock.patch.object(erosion.subprocess, "run", side_effect=AssertionError("scala-cli called")):
            self.assertEqual(erosion.measure(self.tree, self.head), {"methods": 0, "total_mass": 0.0, "erosion": 0.0})

    def test_scala_cli_failure_raises(self):
        open(os.path.join(self.tree, "m/src/A.scala"), "w").write("object Changed\n")
        with mock.patch.dict(os.environ, {"GA_SCALA_CLI": "false"}):
            with self.assertRaises(erosion.ErosionError):
                erosion.measure(self.tree, self.head)


@unittest.skipUnless(shutil.which(os.environ.get("GA_SCALA_CLI", "scala-cli")), "scala-cli not installed")
class ScalaMetric(unittest.TestCase):
    def test_cc_and_sloc_per_method(self):
        ms = {m["name"]: m for m in erosion.method_metrics([FIX])}
        self.assertEqual(ms["small"]["cc"], 5)    # 1 + if + && + 2 cases
        self.assertEqual(ms["small"]["sloc"], 5)
        self.assertEqual(ms["big"]["cc"], 12)     # 1 + 11 ifs
        self.assertEqual(ms["outer"]["cc"], 1)    # inner's if is inner's
        self.assertEqual(ms["outer"]["sloc"], 3)  # the comment line does not count
        self.assertEqual(ms["inner"]["cc"], 2)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd eval/gate-ab && python3 -m unittest tests.test_erosion -v`
Expected: ERROR — `ModuleNotFoundError: No module named 'erosion'`.

- [ ] **Step 3: Write `erosion.scala`**

```scala
//> using scala 3.8.4
//> using dep org.scalameta::scalameta:4.17.3
// erosion.scala <file>...: per-method cyclomatic complexity and SLOC as JSON (spec 2026-10-11 chained feature work §3).
import scala.meta.*

given Dialect = dialects.Scala3

def own(t: Tree): Int = t match
  case _: Term.If | _: Case | _: Term.While | _: Enumerator.Guard => 1
  case a: Term.ApplyInfix if a.op.value == "&&" || a.op.value == "||" => 1
  case _ => 0

// A nested def is its own method: its branches are not the enclosing method's.
def branches(t: Tree): Int = t match
  case _: Defn.Def => 0
  case _ => own(t) + t.children.map(branches).sum

def sloc(lines: Array[String], d: Defn.Def): Int =
  (d.pos.startLine to d.pos.endLine).count { i =>
    val l = lines(i).trim
    l.nonEmpty && !l.startsWith("//") && !l.startsWith("/*") && !l.startsWith("*")
  }

def esc(s: String): String = s.flatMap {
  case '"' => "\\\""
  case '\\' => "\\\\"
  case c => c.toString
}

@main def erosion(files: String*): Unit =
  val rows = files.flatMap { f =>
    val text = String(java.nio.file.Files.readAllBytes(java.nio.file.Paths.get(f)), "UTF-8")
    val lines = text.split("\n", -1)
    Input.VirtualFile(f, text).parse[Source].get.collect { case d: Defn.Def => d }.map { d =>
      s"""{"file":"${esc(f)}","name":"${esc(d.name.value)}","line":${d.pos.startLine + 1},"cc":${1 + branches(d.body)},"sloc":${sloc(lines, d)}}"""
    }
  }
  println(rows.mkString("{\"methods\":[", ",", "]}"))
```

- [ ] **Step 4: Write `erosion.py`**

```python
#!/usr/bin/env python3
"""erosion.py <tree> <head>: the erosion figure of the main .scala files that differ from <head> (spec 2026-10-11 chained
feature work §3). Per-method CC and SLOC come from erosion.scala (scala-cli + scalameta); mass = CC * sqrt(SLOC);
erosion = share of mass in methods with CC > 10 (SlopCodeBench). Env GA_SCALA_CLI (default scala-cli)."""
import json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CC_ERODED = 10


class ErosionError(Exception):
    """scala-cli failed or printed something that is not the expected JSON."""


def _skipped_dir(name):
    return name.startswith(".") or name == "out" or name.startswith("out-") or name == "test"


def changed_main_files(tree, head):
    found = []
    for root, dirs, files in os.walk(tree):
        dirs[:] = sorted(d for d in dirs if not _skipped_dir(d))
        for f in sorted(files):
            if not f.endswith(".scala"):
                continue
            p = os.path.join(root, f)
            h = os.path.join(head, os.path.relpath(p, tree))
            if not os.path.isfile(h) or open(p, "rb").read() != open(h, "rb").read():
                found.append(p)
    return sorted(found)


def aggregate(methods):
    total = eroded = 0.0
    for m in methods:
        mass = m["cc"] * math.sqrt(m["sloc"])
        total += mass
        if m["cc"] > CC_ERODED:
            eroded += mass
    return {"methods": len(methods), "total_mass": round(total, 3), "erosion": round(eroded / total, 4) if total else 0.0}


def method_metrics(files):
    cmd = [os.environ.get("GA_SCALA_CLI", "scala-cli"), "run", "-q", os.path.join(HERE, "erosion.scala"), "--"] + list(files)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise ErosionError("cannot run %s: %s" % (cmd[0], e))
    if r.returncode != 0:
        raise ErosionError("erosion.scala exit %d: %s" % (r.returncode, r.stderr.strip()[-500:]))
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])["methods"]
    except (ValueError, KeyError, IndexError):
        raise ErosionError("erosion.scala printed no JSON: %r" % r.stdout[-300:])


def measure(tree, head):
    files = changed_main_files(tree, head)
    return aggregate(method_metrics(files)) if files else aggregate([])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: erosion.py <tree> <head>")
    try:
        print(json.dumps(measure(sys.argv[1], sys.argv[2])))
    except ErosionError as e:
        sys.exit("erosion.py: %s" % e)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd eval/gate-ab && python3 -m unittest tests.test_erosion -v`
Expected: 7 tests OK (the scala-cli test compiles the script once; first run may take a minute).

- [ ] **Step 6: Commit**

```bash
git add eval/gate-ab/erosion.scala eval/gate-ab/erosion.py eval/gate-ab/tests/fixtures/erosion/F.scala eval/gate-ab/tests/test_erosion.py
git commit -m "gate-ab: erosion figure (scalameta CC x sqrt(SLOC), share above CC 10) for changed main files

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 2: `run.sh` seeded from a previous step

**Files:**
- Modify: `eval/gate-ab/run.sh` (the `cp -R "$base/tree" "$rd/repo"` line)
- Modify: `eval/gate-ab/lib.sh` (`ga_install_engine` commit)
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Produces: env `GA_SEED_TREE=<path to a final-tree.tar.gz>` — when set, `run.sh` unpacks `repo/` from it, drops its `.git`, and commits it as a fresh `base`. Unset: unchanged behaviour.

- [ ] **Step 1: Write the failing tests**

In `eval/gate-ab/tests/shell-test.sh`, insert immediately after the line containing `check "run g outer Claude Code env not inherited"`:

```sh
# Chained runs (spec 2026-10-11): GA_SEED_TREE starts the repo from the previous step's final tree, as a fresh repository
seed=$rd/t1-g-1/final-tree.tar.gz
runenv GA_SEED_TREE="$seed" FAKE_ARGS=$tmp/args-s.txt FAKE_PROBE= FAKE_PROBED=$tmp/probed-s.txt FAKE_LS=$tmp/ls-s.txt $SH "$tmp/home/run.sh" t1 u 2 >/dev/null 2>&1; check "seeded run exit 0" "$?" "0"
check "seeded run keeps the previous step's work" "$(grep -c 'agent wrote this' "$rd/t1-u-2/repo/agent-note.txt")" "2"
check "seeded run diff holds only this step's work" "$(grep -c '^+agent wrote this' "$rd/t1-u-2/final.diff")" "1"
check "seeded run history is fresh (base + arm)" "$(git -C "$rd/t1-u-2/repo" rev-list --count HEAD)" "2"
git -C "$rd/t1-u-2/repo" rev-parse -q --verify refs/tags/base >/dev/null && ok "seeded run base tag" || bad "seeded run base tag"
check "seeded u run settings rewritten" "$(cat "$rd/t1-u-2/repo/.claude/settings.json")" '{"permissions":{}}'
runenv GA_SEED_TREE="$tmp/nope.tar.gz" FAKE_ARGS=$tmp/args-s2.txt FAKE_PROBE= FAKE_PROBED=$tmp/probed-s2.txt FAKE_LS=$tmp/ls-s2.txt $SH "$tmp/home/run.sh" t1 u 3 >/dev/null 2>&1; check "missing seed tree fails" "$?" "1"
```

Also add, in the `# --- lib.sh` section, a test that `ga_install_engine` can run twice on the same tree. Insert after the line `check "FR tasks known" "$out" "yes"`:

```sh
# Seeded gs steps re-install an identical engine: the commit must not fail on an unchanged tree
eng=$(mktemp -d); mkdir -p "$eng/t/kit/harness" "$eng/r"
printf '#!/bin/sh\nmkdir -p "$1/.dsh/policy"; : >"$1/.dsh/frozen-paths"; echo engine >"$1/.dsh/engine.txt"\n' >"$eng/t/kit/harness/install.sh"
( cd "$eng/r" && git init -q && echo x >x && git add -A && git -c user.name=t -c user.email=t@t commit -qm r )
$SH -c "GA_TEMPLATE='$eng/t'; . '$ga/lib.sh'; ga_install_engine '$eng/r' safety && ga_install_engine '$eng/r' safety" >/dev/null 2>&1
check "engine install twice" "$?" "0"
rm -rf "$eng"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | grep -E '^FAIL|passed|failed' | tail -12`
Expected: FAIL lines for `seeded run keeps the previous step's work` (1, not 2), `seeded run history is fresh`, `missing seed tree fails`, and `engine install twice`.

- [ ] **Step 3: Implement**

In `eval/gate-ab/run.sh`, replace the line `cp -R "$base/tree" "$rd/repo"` with:

```sh
if [ -n "${GA_SEED_TREE:-}" ]; then
  # Chained runs (spec 2026-10-11 chained feature work): the previous step's final tree, re-based as a fresh repository.
  [ -f "$GA_SEED_TREE" ] || ga_die "seed tree $GA_SEED_TREE missing"
  tar -xzf "$GA_SEED_TREE" -C "$rd" || ga_die "unpack $GA_SEED_TREE"
  [ -d "$rd/repo" ] || ga_die "seed tree $GA_SEED_TREE has no repo/"
  rm -rf "$rd/repo/.git"
  ( cd "$rd/repo" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm base ) ||
    ga_die "seed tree: git init failed"
else
  cp -R "$base/tree" "$rd/repo"
fi
```

In `eval/gate-ab/lib.sh`, in `ga_install_engine`, change `commit -qm "engine, turn-end mode $2"` to `commit -qm "engine, turn-end mode $2" --allow-empty`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -3; SH=dash sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1`
Expected: `0 failed` under both shells (if dash is not installed, record that and use sh only).

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/run.sh eval/gate-ab/lib.sh eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: run.sh GA_SEED_TREE — a chained step starts from the previous step's final tree

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 3: Chain checks (`chaincheck.py`)

**Files:**
- Create: `eval/gate-ab/chaincheck.py`
- Test: `eval/gate-ab/tests/test_chaincheck.py`

**Interfaces:**
- Env: `GA_ROOT` (run root), `GA_HOME` (harness dir holding `tasks/`, default `score.HERE`), `GA_MILL` (as score.py).
- Consumes: `score.read_task_env(path) -> (TASK_MODULE, HIDDEN_SPEC, CUT_FILES, FEATURE)`, `score.suite_fq(text) -> str|None`, `score.run_mill(cwd, args, out_dir, log_path) -> (rc, timed_out)`, `score.hidden_counts(log_text, fq) -> (passed, failed, compiled)`, `score._read(path)`, `score._home()`, `score.HERE`, `score.ScoreError`; `erosion.measure(tree, head) -> dict`, `erosion.ErosionError`.
- Produces: CLI `python3 chaincheck.py <run-dir> [<earlier-run-dir>...]` writes `<run-dir>/chain.json`: `{"run_id", "earlier": [{"task", "status": "pass"|"fail"|"na", "passed", "failed", "timed_out"}], "chain_regressions": int, "erosion": {methods, total_mass, erosion} | null, "error": str|null}`. Pure: `own_passed(score_rec) -> bool`, `earlier_status(compiled, passed, failed, timed_out) -> "pass"|"fail"`, `chain_regressions(earlier) -> int`.

- [ ] **Step 1: Write the failing tests**

`eval/gate-ab/tests/test_chaincheck.py`:

```python
import json, os, shutil, stat, sys, tempfile, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import chaincheck


class Pure(unittest.TestCase):
    def test_own_passed(self):
        self.assertTrue(chaincheck.own_passed({"hidden_compiled": True, "hidden_pass_ratio": 1.0}))
        self.assertFalse(chaincheck.own_passed({"hidden_compiled": True, "hidden_pass_ratio": 0.67}))
        self.assertFalse(chaincheck.own_passed({"hidden_compiled": False, "hidden_pass_ratio": 1.0}))

    def test_earlier_status(self):
        self.assertEqual(chaincheck.earlier_status(True, 3, 0, False), "pass")
        self.assertEqual(chaincheck.earlier_status(True, 2, 1, False), "fail")
        self.assertEqual(chaincheck.earlier_status(False, 0, 0, False), "fail")   # spec no longer compiles
        self.assertEqual(chaincheck.earlier_status(True, 3, 0, True), "fail")     # timeout
        self.assertEqual(chaincheck.earlier_status(True, 0, 0, False), "fail")    # nothing ran

    def test_chain_regressions_ignore_na(self):
        self.assertEqual(chaincheck.chain_regressions([{"status": "fail"}, {"status": "na"}, {"status": "pass"}]), 1)


FAKE_MILL = """#!/bin/sh
# fake mill: <...> <module>.testOnly <fq>; a spec file containing BROKEN does not compile; FAILS fails one test
fq=$(eval echo \\${$#})
if grep -rq BROKEN m/test; then echo "Compilation failed"; exit 1; fi
echo "Running Test Class $fq"
if grep -rq FAILS m/test; then echo "- one 1ms"; exit 1; fi
echo "+ one 1ms"
"""


class Main(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.root = os.path.join(self.d, "root"); self.home = os.path.join(self.d, "home")
        self.rd = os.path.join(self.root, "runs", "t3-u-1")
        os.makedirs(os.path.join(self.rd, "repo", "m", "test", "src"))
        mill = os.path.join(self.rd, "repo", "mill"); open(mill, "w").write(FAKE_MILL)
        os.chmod(mill, os.stat(mill).st_mode | stat.S_IEXEC)
        os.makedirs(os.path.join(self.rd, "repo", "out-agent")); open(os.path.join(self.rd, "repo", "out-agent", "junk"), "w").write("x")
        self.earlier = []
        for task, body, passed in (("t1", "object S1 extends SimpleIOSuite", True), ("t2", "object S2 extends SimpleIOSuite // BROKEN", True),
                                   ("t9", "object S9 extends SimpleIOSuite", False)):
            ed = os.path.join(self.root, "runs", task + "-u-1"); os.makedirs(ed)
            json.dump({"task": task, "hidden_compiled": True, "hidden_pass_ratio": 1.0 if passed else 0.5}, open(os.path.join(ed, "score.json"), "w"))
            hs = os.path.join(self.root, "base", task, "hidden", "m", "test", "src", task + "Spec.scala")
            os.makedirs(os.path.dirname(hs)); open(hs, "w").write("package p\n" + body + "\n")
            os.makedirs(os.path.join(self.home, "tasks", task))
            open(os.path.join(self.home, "tasks", task, "task.env"), "w").write(
                "TASK_MODULE='m.test'\nHIDDEN_SPEC='m/test/src/%sSpec.scala'\nCUT_FILES=''\nFEATURE='f'\n" % task)
            self.earlier.append(ed)

    def tearDown(self):
        shutil.rmtree(self.d)

    def run_main(self):
        env = {"GA_ROOT": self.root, "GA_HOME": self.home, "GA_MILL": "./mill"}
        with mock.patch.dict(os.environ, env), mock.patch.object(chaincheck.erosion, "measure", return_value={"methods": 1, "total_mass": 2.0, "erosion": 0.0}):
            return chaincheck.main(self.rd, self.earlier)

    def test_statuses_and_record(self):
        out = self.run_main()
        self.assertEqual([(e["task"], e["status"]) for e in out["earlier"]], [("t1", "pass"), ("t2", "fail"), ("t9", "na")])
        self.assertEqual(out["chain_regressions"], 1)
        self.assertEqual(out["erosion"], {"methods": 1, "total_mass": 2.0, "erosion": 0.0})
        self.assertIsNone(out["error"])
        self.assertEqual(json.load(open(os.path.join(self.rd, "chain.json"))), out)
        self.assertFalse(os.path.exists(os.path.join(self.rd, "chain-tree")))
        self.assertFalse(os.path.exists(os.path.join(self.rd, "repo", "m", "test", "src", "t1Spec.scala")))  # repo untouched

    def test_infrastructure_error_is_recorded(self):
        shutil.rmtree(os.path.join(self.root, "base", "t1"))
        out = self.run_main()
        self.assertIsNotNone(out["error"])
        self.assertTrue(os.path.exists(os.path.join(self.rd, "chain.json")))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd eval/gate-ab && python3 -m unittest tests.test_chaincheck -v`
Expected: ERROR — `No module named 'chaincheck'`.

- [ ] **Step 3: Implement `eval/gate-ab/chaincheck.py`**

```python
#!/usr/bin/env python3
"""chaincheck.py <run-dir> [<earlier-run-dir>...]: chain checks for one chained step (spec 2026-10-11 chained feature
work §3). Each earlier step's hidden spec runs on this step's final tree (status na when that spec had not passed at the
end of its own step), then the erosion figure of the tree. Writes <run-dir>/chain.json; infrastructure trouble goes to
its "error" field, never to a status."""
import json, os, shutil, sys

import erosion
import score


def own_passed(rec):
    return bool(rec.get("hidden_compiled")) and rec.get("hidden_pass_ratio") == 1.0


def earlier_status(compiled, passed, failed, timed_out):
    return "pass" if compiled and not timed_out and failed == 0 and passed > 0 else "fail"


def chain_regressions(earlier):
    return sum(1 for e in earlier if e["status"] == "fail")


def _no_out(repo):
    return lambda d, names: {n for n in names if n == "out" or n.startswith("out-")} if d == repo else set()


def main(rd, earlier_dirs):
    ga_root = os.environ.get("GA_ROOT") or os.path.join(score._home(), "gate-eval")
    repo = os.path.join(rd, "repo")
    tree = os.path.join(rd, "chain-tree")
    out = dict(run_id=os.path.basename(rd), earlier=[], chain_regressions=0, erosion=None, error=None)
    try:
        shutil.rmtree(tree, ignore_errors=True)
        shutil.copytree(repo, tree, symlinks=True, ignore=_no_out(repo))
        for ed in earlier_dirs:
            rec = json.load(open(os.path.join(ed, "score.json")))
            task = rec["task"]
            if not own_passed(rec):
                out["earlier"].append(dict(task=task, status="na", passed=0, failed=0, timed_out=False))
                continue
            ga_home = os.environ.get("GA_HOME") or score.HERE
            module, hidden_spec, _cut, _feature = score.read_task_env(os.path.join(ga_home, "tasks", task, "task.env"))
            src = os.path.join(ga_root, "base", task, "hidden", hidden_spec)
            if not os.path.isfile(src):
                raise score.ScoreError("hidden spec %s missing" % src)
            fq = score.suite_fq(score._read(src))
            if not fq:
                raise score.ScoreError("no suite object in " + src)
            dst = os.path.join(tree, hidden_spec)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            log = os.path.join(rd, "chain-%s.log" % task)
            _rc, to = score.run_mill(tree, [module + ".testOnly", fq], "out-chain", log)
            p, f, compiled = score.hidden_counts(score._read(log), fq)
            out["earlier"].append(dict(task=task, status=earlier_status(compiled, p, f, to), passed=p, failed=f, timed_out=to))
            os.remove(dst)  # one spec at a time: a spec that no longer compiles must not mask the next
        out["chain_regressions"] = chain_regressions(out["earlier"])
        out["erosion"] = erosion.measure(repo, os.path.join(ga_root, "head"))
    except (OSError, ValueError, KeyError, score.ScoreError, erosion.ErosionError, score.subprocess.CalledProcessError) as e:
        out["error"] = "%s: %s" % (type(e).__name__, e)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    with open(os.path.join(rd, "chain.json"), "w") as fh:
        json.dump(out, fh, indent=2)
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: chaincheck.py <run-dir> [<earlier-run-dir>...]")
    r = main(sys.argv[1], sys.argv[2:])
    print("chain %s: regressions %s, erosion %s%s" % (r["run_id"], r["chain_regressions"], r["erosion"],
                                                     "" if r["error"] is None else ", ERROR " + r["error"]))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd eval/gate-ab && python3 -m unittest tests.test_chaincheck -v`
Expected: 5 tests OK. If `hidden_counts` does not see the fake output as a suite section, read `score._sections`/`_match_suite` and adjust the fake mill's lines (not the production code) to the real weaver shape shown in `tests/test_score.py` (`Running Test Class a.B` / `+ ok 1ms`).

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/chaincheck.py eval/gate-ab/tests/test_chaincheck.py
git commit -m "gate-ab: chaincheck.py — earlier steps' hidden specs on a chained step's tree, plus erosion

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 4: Chain mode in `campaign.sh`

**Files:**
- Modify: `eval/gate-ab/campaign.sh`
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Consumes: `run.sh` with `GA_SEED_TREE` (Task 2); `chaincheck.py <rd> <earlier rd>...` (Task 3); `prepare-chain.sh <task>...` (Task 5; writes `$GA_ROOT/chain-validation.txt`).
- Produces: env `GA_CHAIN="<task> <task> ..."` — chain mode. Overrides for tests: `GA_CHAINCHECK` (default `python3 "$GA_HOME/chaincheck.py"`), `GA_PREPARE_CHAIN` (default `sh "$GA_HOME/prepare-chain.sh"`). Order: for rep, for arm, the chain's steps in order. Step k>1 gets `GA_SEED_TREE=$GA_ROOT/runs/<step k-1 id>/final-tree.tar.gz`. When a step's agent runs (fresh or retry), every later step of that chain is deleted and redone. `chaincheck` runs after each step whose agent ran or whose `chain.json` is missing or has a non-null error. Log line per check in `campaign.log`: `<date> chain <id> regressions=<n>`.

- [ ] **Step 1: Write the failing tests**

Append to `eval/gate-ab/tests/shell-test.sh`, before the final summary lines (the line that prints passed/failed counts):

```sh
# --- campaign.sh chain mode (spec 2026-10-11 chained feature work)
tmp=$(mktemp -d); croot=$tmp/root; mkdir -p "$croot/runs" "$tmp/home"
cp "$ga/lib.sh" "$ga/campaign.sh" "$tmp/home/"
for t in fr-pan fr-exclusive-solo fr-mode-leds fr-tuning; do
  mkdir -p "$croot/base/$t" "$tmp/home/tasks/$t"; printf 'a=yes\nb=yes\nc=yes\n' >"$croot/base/$t/validation.txt"; : >"$tmp/home/tasks/$t/task.env"
done
echo '{}' >"$croot/gated-settings.json"; echo '{}' >"$croot/head-baseline.json"
printf 'patches_apply=yes\nreference_passes_all=yes\n' >"$croot/chain-validation.txt"
cat >"$tmp/run" <<'FAKE'
#!/bin/sh
echo "$1 $2 $3 seed=${GA_SEED_TREE:-}" >>"$FAKE_RUNLOG"; d=$GA_ROOT/runs/$1-$2-$3; rm -rf "$d"; mkdir -p "$d"; echo '{}' >"$d/run.json"; : >"$d/final-tree.tar.gz"
FAKE
cat >"$tmp/score" <<'FAKE'
#!/bin/sh
echo '{"solved": true, "error": null}' >"$1/score.json"
FAKE
cat >"$tmp/chk" <<'FAKE'
#!/bin/sh
echo "$*" >>"$FAKE_CHKLOG"; echo '{"chain_regressions": 0, "error": null}' >"$1/chain.json"
FAKE
chmod +x "$tmp/run" "$tmp/score" "$tmp/chk"
cenv() { env GA_CAFFEINATED=1 GA_HOME=$tmp/home GA_ROOT=$croot GA_RUN=$tmp/run GA_SCORE=$tmp/score GA_CHAINCHECK=$tmp/chk \
  GA_PREPARE=false GA_PREPARE_CHAIN=false GA_BASELINE=false FAKE_RUNLOG=$tmp/runlog FAKE_CHKLOG=$tmp/chklog \
  GA_CHAIN="fr-pan fr-exclusive-solo fr-mode-leds fr-tuning" GA_ARMS="u gs" GA_REPS=1 "$@"; }
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1; check "chain campaign exit 0" "$?" "0"
check "chain runs in order with seeds" "$(cat "$tmp/runlog")" "fr-pan u 1 seed=
fr-exclusive-solo u 1 seed=$croot/runs/fr-pan-u-1/final-tree.tar.gz
fr-mode-leds u 1 seed=$croot/runs/fr-exclusive-solo-u-1/final-tree.tar.gz
fr-tuning u 1 seed=$croot/runs/fr-mode-leds-u-1/final-tree.tar.gz
fr-pan gs 1 seed=
fr-exclusive-solo gs 1 seed=$croot/runs/fr-pan-gs-1/final-tree.tar.gz
fr-mode-leds gs 1 seed=$croot/runs/fr-exclusive-solo-gs-1/final-tree.tar.gz
fr-tuning gs 1 seed=$croot/runs/fr-mode-leds-gs-1/final-tree.tar.gz"
check "chain check gets the earlier steps" "$(sed -n 3p "$tmp/chklog")" "$croot/runs/fr-mode-leds-u-1 $croot/runs/fr-pan-u-1 $croot/runs/fr-exclusive-solo-u-1"
check "chain check on step 1 has no earlier steps" "$(sed -n 1p "$tmp/chklog")" "$croot/runs/fr-pan-u-1"
# resume: step 2 of the u chain lost its score -> steps 2..4 of that chain are redone, the gs chain is skipped
rm "$croot/runs/fr-exclusive-solo-u-1/score.json"; : >"$tmp/runlog"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "chain resume redoes the rest of that chain only" "$(cut -d' ' -f1-3 "$tmp/runlog" | tr '\n' ';')" "fr-exclusive-solo u 1;fr-mode-leds u 1;fr-tuning u 1;"
# a chain check with an error is redone without re-running the agent
echo '{"error": "boom"}' >"$croot/runs/fr-tuning-gs-1/chain.json"; : >"$tmp/runlog"; : >"$tmp/chklog"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "chain check redone after an error" "$(cat "$tmp/runlog")|$(cut -d' ' -f1 "$tmp/chklog")" "|$croot/runs/fr-tuning-gs-1"
# a chain whose validation is not all yes does not start
printf 'patches_apply=no\n' >"$croot/chain-validation.txt"; : >"$tmp/runlog"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1; check "chain refuses an invalid chain" "$?" "1"
check "chain refusal ran nothing" "$(cat "$tmp/runlog")" ""
rm -rf "$tmp"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | grep -E '^FAIL' | head`
Expected: FAIL on `chain runs in order with seeds` (the campaign ignores GA_CHAIN and loops GA_TASKS), and the other chain checks.

- [ ] **Step 3: Implement**

In `eval/gate-ab/campaign.sh`:

1. After the line `prep=${GA_PREPARE:-sh "$GA_HOME/prepare.sh"}; bl=...`, add:

```sh
chk=${GA_CHAINCHECK:-python3 "$GA_HOME/chaincheck.py"}; prepc=${GA_PREPARE_CHAIN:-sh "$GA_HOME/prepare-chain.sh"}
unset GA_SEED_TREE  # set only per chained step below
```

2. In `one()`, record whether the agent ran: change `if [ "$how" != rescore ]; then $run "$1" "$2" "$3"; rc=$?; fi` to

```sh
  ran=0
  if [ "$how" != rescore ]; then $run "$1" "$2" "$3"; rc=$?; ran=1; fi
```

and change the skip line to `elif [ -z "$e" ]; then echo "skip $id"; ran=0; return 0`.

3. Replace the line `if [ "${1:-}" = --smoke ]; then tasks=midi-synth; else tasks=$GA_TASKS; fi` and the task-validation loop above it with:

```sh
if [ -n "${GA_CHAIN:-}" ]; then
  # Chain mode (spec 2026-10-11 chained feature work): GA_CHAIN's steps, in order, one tree per (arm, rep).
  for t in $GA_CHAIN; do case " $GA_ALL_TASKS " in *" $t "*) ;; *) ga_die "GA_CHAIN: unknown task '$t'" ;; esac; done
  tasks=$GA_CHAIN
else
  [ -n "$(echo $GA_TASKS)" ] || ga_die "GA_TASKS is empty"
  for t in $GA_TASKS; do case " $GA_ALL_TASKS " in *" $t "*) ;; *) ga_die "GA_TASKS: unknown task '$t'" ;; esac; done
  if [ "${1:-}" = --smoke ]; then tasks=midi-synth; else tasks=$GA_TASKS; fi
fi
```

4. After the line `[ -f "$GA_ROOT/head-baseline.json" ] || $bl || ga_die "HEAD baseline failed"`, add:

```sh
if [ -n "${GA_CHAIN:-}" ]; then
  cv=$GA_ROOT/chain-validation.txt
  # missing -> validate now; any line not =yes -> refuse (a failed validation is never silently re-run)
  # shellcheck disable=SC2086
  [ -s "$cv" ] || $prepc $GA_CHAIN || ga_die "prepare-chain failed (see $cv)"
  ! grep -qv '=yes$' "$cv" || ga_die "chain validation failed (see $cv)"
  chain_check_needed() {  # <id>: 0 when chain.json is missing or carries an error
    python3 -c "import json,sys;sys.exit(0 if json.load(open(sys.argv[1])).get('error') is not None else 1)" "$GA_ROOT/runs/$1/chain.json" 2>/dev/null && return 0
    [ ! -f "$GA_ROOT/runs/$1/chain.json" ]
  }
  for rep in $reps; do for arm in $arms; do
    prev=; earlier=; redo=0
    for task in $tasks; do
      id=$(ga_run_id "$task" "$arm" "$rep") || exit 1
      [ "$redo" = 1 ] && rm -rf "$GA_ROOT/runs/$id"
      if [ -n "$prev" ]; then GA_SEED_TREE=$GA_ROOT/runs/$prev/final-tree.tar.gz; export GA_SEED_TREE; else unset GA_SEED_TREE; fi
      one "$task" "$arm" "$rep"
      [ "$ran" = 1 ] && redo=1
      if [ "$ran" = 1 ] || chain_check_needed "$id"; then
        # shellcheck disable=SC2086
        $chk "$GA_ROOT/runs/$id" $earlier
        n=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('chain_regressions'))" "$GA_ROOT/runs/$id/chain.json" 2>/dev/null || echo none)
        printf '%s chain %s regressions=%s\n' "$(date '+%F %T')" "$id" "$n" >> "$GA_ROOT/campaign.log"
      fi
      earlier="$earlier $GA_ROOT/runs/$id"; prev=$id
    done
    unset GA_SEED_TREE
  done; done
  exit 0
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1; SH=dash sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1`
Expected: `0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/campaign.sh eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: campaign GA_CHAIN mode — ordered steps, seeds, redo the rest of a chain, chain checks

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 5: Chain validation (`prepare-chain.sh`)

**Files:**
- Create: `eval/gate-ab/prepare-chain.sh`
- Test: `eval/gate-ab/tests/shell-test.sh`

**Interfaces:**
- Consumes: `$GA_ROOT/head` (git repo, from `warm-cache.sh`), `$GA_ROOT/head-baseline.json` (`{"modules": {...}}`), `$GA_ROOT/base/<task>/hidden/<HIDDEN_SPEC>` (from `prepare.sh`), each task's `REFERENCE_PATCH`; `erosion.py <tree> <head>` (Task 1; override `GA_EROSION`, default `python3 "$GA_HOME/erosion.py"`).
- Produces: `prepare-chain.sh <task>...` writes `$GA_ROOT/chain-validation.txt` (`patches_apply=yes|no`, `reference_passes_all=yes|no`) and `$GA_ROOT/chain-reference-erosion.json` (`[{"task": .., "methods": .., "total_mass": .., "erosion": ..}, ...]`, one per step, HEAD + patches 1..k); exit 0 only when both lines are yes.

- [ ] **Step 1: Write the failing tests**

Append to `eval/gate-ab/tests/shell-test.sh`, before the final summary lines:

```sh
# --- prepare-chain.sh (spec 2026-10-11 chained feature work §3)
tmp=$(mktemp -d); proot=$tmp/root; mkdir -p "$proot/head/m/src" "$tmp/home/tasks/c1" "$tmp/home/tasks/c2" "$tmp/hsrc"
cp "$ga/lib.sh" "$ga/prepare-chain.sh" "$ga/timeout.py" "$tmp/home/"
cat >"$proot/head/mill" <<'MILL'
#!/bin/sh
echo "$*" >>"$FAKE_MILL_LOG"
[ -n "${FAKE_MILL_FAIL:-}" ] && { echo "[error] m.test 1 tests failed:"; exit 1; }
exit 0
MILL
chmod +x "$proot/head/mill"
printf 'object A {\n  def f = 1\n}\n' >"$proot/head/m/src/A.scala"
( cd "$proot/head" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm head )
echo '{"modules": {"m.test": true, "n.test": true}}' >"$proot/head-baseline.json"
( cd "$tmp/hsrc" && echo spec >HSpec.scala && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm h )
mkpatch() {  # <task> <old line> <new line>
  w=$(mktemp -d); cp -R "$proot/head/." "$w/"; [ -n "${PREV:-}" ] && ( cd "$w" && git apply "$PREV" )
  ( cd "$w" && git add -A && git -c user.name=t -c user.email=t@t commit -qm p >/dev/null 2>&1; sed -i.bak "s/$2/$3/" m/src/A.scala && rm m/src/A.scala.bak && git diff >"$tmp/home/tasks/$1/ref.patch" )
  rm -rf "$w"
  printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='m/test/src/%sSpec.scala'\nREFERENCE_PATCH='ref.patch'\nFEATURE='f'\n" "$1" >"$tmp/home/tasks/$1/task.env"
  mkdir -p "$proot/base/$1/hidden/m/test/src"; echo "object ${1}Spec" >"$proot/base/$1/hidden/m/test/src/${1}Spec.scala"
}
mkpatch c1 'def f = 1' 'def f = 2'
PREV=$tmp/home/tasks/c1/ref.patch mkpatch c2 'def f = 2' 'def f = 3'
printf '#!/bin/sh\necho "{\\"methods\\": 1, \\"total_mass\\": 1.0, \\"erosion\\": 0.0}"\n' >"$tmp/ero"; chmod +x "$tmp/ero"
penv2() { env GA_HOME=$tmp/home GA_ROOT=$proot GA_HOLDOUT_SRC=$tmp/hsrc GA_HOLDOUT_COMMIT=HEAD GA_EROSION=$tmp/ero FAKE_MILL_LOG=$tmp/pmill.log "$@"; }
penv2 $SH "$tmp/home/prepare-chain.sh" c1 c2 >/dev/null 2>&1; check "prepare-chain exit 0" "$?" "0"
check "prepare-chain validation" "$(cat "$proot/chain-validation.txt")" "patches_apply=yes
reference_passes_all=yes"
check "prepare-chain reference erosion per step" "$(python3 -c 'import json,sys;print(" ".join(e["task"] for e in json.load(open(sys.argv[1]))))' "$proot/chain-reference-erosion.json")" "c1 c2"
grep -q 'm.test + n.test' "$tmp/pmill.log" && grep -q 'holdout.test' "$tmp/pmill.log" && ok "prepare-chain runs all modules and the holdout" || bad "prepare-chain runs all modules and the holdout" "$(cat "$tmp/pmill.log")"
check "prepare-chain leaves head untouched" "$(cat "$proot/head/m/src/A.scala" | sed -n 2p)" "  def f = 1"
penv2 FAKE_MILL_FAIL=1 $SH "$tmp/home/prepare-chain.sh" c1 c2 >/dev/null 2>&1; check "prepare-chain failing tests exit 1" "$?" "1"
check "prepare-chain failing tests recorded" "$(sed -n 2p "$proot/chain-validation.txt")" "reference_passes_all=no"
penv2 $SH "$tmp/home/prepare-chain.sh" c2 c1 >/dev/null 2>&1; check "prepare-chain conflicting order exit 1" "$?" "1"
check "prepare-chain conflicting order recorded" "$(sed -n 1p "$proot/chain-validation.txt")" "patches_apply=no"
rm -rf "$tmp"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | grep -E '^FAIL' | head`
Expected: FAIL on every `prepare-chain` check (`prepare-chain.sh` does not exist).

- [ ] **Step 3: Implement `eval/gate-ab/prepare-chain.sh`**

```sh
#!/bin/sh
# Chain validation (spec 2026-10-11 chained feature work §3): on HEAD + the chain's reference patches in order (git apply -3),
# every step's hidden spec, every existing test module and the holdout pass. Also the reference erosion line (HEAD + patches 1..k).
# prepare-chain.sh <task>... -> $GA_ROOT/chain-validation.txt, $GA_ROOT/chain-reference-erosion.json
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -ge 1 ] || ga_die "usage: prepare-chain.sh <task>..."
h=$GA_ROOT/head
[ -d "$h/.git" ] || ga_die "no $h — run warm-cache.sh first"
[ -f "$GA_ROOT/head-baseline.json" ] || ga_die "no $GA_ROOT/head-baseline.json — run score.py --baseline first"
ero=${GA_EROSION:-python3 "$GA_HOME/erosion.py"}
cvf=$GA_ROOT/chain-validation.txt; ref=$GA_ROOT/chain-reference-erosion.json; rm -f "$cvf" "$ref"
cv=$GA_ROOT/chain-validate; rm -rf "$cv"; cp -R "$h" "$cv"; rm -rf "$cv/out"
mill_in() { # <cap-seconds> <dir> <args...>
  cap=$1; d=$2; shift 2
  ( cd "$d" && MILL_OUTPUT_DIR=out python3 "$GA_HOME/timeout.py" "$cap" -- ./mill --no-daemon -j 1 --ticker false --color false "$@" )
}
ap=yes; rp=no; specs=; tmods=; sep=
printf '[' >"$ref.tmp"
for task in "$@"; do
  HIDDEN_SPEC_SRC=; REFERENCE_PATCH=; ga_task_env "$task"
  [ -n "$REFERENCE_PATCH" ] || ga_die "task $task has no reference patch"
  src=$GA_ROOT/base/$task/hidden/$HIDDEN_SPEC
  [ -f "$src" ] || ga_die "no $src — run prepare.sh $task first"
  if ! ( cd "$cv" && git apply -3 "$GA_HOME/tasks/$task/$REFERENCE_PATCH" &&
         git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm "$task" ) \
       >"$GA_ROOT/chain-apply-$task.log" 2>&1; then
    ap=no; break
  fi
  e=$($ero "$cv" "$h") || ga_die "erosion on the reference after $task failed"
  printf '%s{"task": "%s", %s' "$sep" "$task" "${e#\{}" >>"$ref.tmp"; sep=', '
  specs="$specs $HIDDEN_SPEC=$src"
  case " $tmods " in *" $TASK_MODULE "*) ;; *) tmods="$tmods $TASK_MODULE" ;; esac
done
printf ']\n' >>"$ref.tmp"
if [ "$ap" = yes ]; then
  mv "$ref.tmp" "$ref"
  for s in $specs; do mkdir -p "$cv/$(dirname "${s%%=*}")"; cp "${s#*=}" "$cv/${s%%=*}"; done
  mods=$(python3 -c 'import json,sys;print(" + ".join(sorted(set(json.load(open(sys.argv[1]))["modules"]) | set(sys.argv[2:]))))' \
    "$GA_ROOT/head-baseline.json" $tmods) || ga_die "read $GA_ROOT/head-baseline.json"
  ho=$GA_ROOT/chain-holdout; rm -rf "$ho"; mkdir -p "$ho"
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | tar -x -C "$ho" || ga_die "holdout export"
  hod=$(CDPATH= cd -- "$ho" && pwd -P)
  # shellcheck disable=SC2086
  mill_in 2400 "$cv" -k $mods >"$GA_ROOT/chain-reference-all.log" 2>&1 &&
    ( export DSH_HOLDOUT_DIR="$hod"; mill_in 600 "$cv" holdout.test ) >>"$GA_ROOT/chain-reference-all.log" 2>&1 && rp=yes
  rm -rf "$ho"
else
  rm -f "$ref.tmp"
fi
rm -rf "$cv"
printf 'patches_apply=%s\nreference_passes_all=%s\n' "$ap" "$rp" >"$cvf"
cat "$cvf"
[ "$ap$rp" = yesyes ]
```

Note: the `mods` set already contains every hidden spec's module because the specs sit in existing test modules; the union with `$tmods` covers a spec in a module the baseline lacks.

- [ ] **Step 4: Run tests to verify they pass**

Run: `sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1; SH=dash sh eval/gate-ab/tests/shell-test.sh 2>&1 | tail -1`
Expected: `0 failed` under both.

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/prepare-chain.sh eval/gate-ab/tests/shell-test.sh
git commit -m "gate-ab: prepare-chain.sh — chain validation on HEAD + reference patches, reference erosion line

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 6: Chain report and verdicts (`chain_report.py`)

**Files:**
- Create: `eval/gate-ab/chain_report.py`
- Test: `eval/gate-ab/tests/test_chain_report.py`

**Interfaces:**
- Consumes: `runs/<task>-<arm>-<rep>/score.json` (`solved`, `false_done`, `regression_count`, `wall_seconds`, `cost_usd`, `error`), `runs/.../chain.json` (Task 3), `chain-reference-erosion.json` (Task 5).
- Produces: `python3 chain_report.py <root> <task>...` writes `<root>/chain-report.md` and prints it. Pure: `step_failures(score, chain) -> int`, `gate_verdict(fail_u, fail_gs) -> str`, `erosion_rises(chains, ref_last) -> (int, int)` (rising chains, chains counted), `item16_verdict(rising, counted) -> str`.

- [ ] **Step 1: Write the failing tests**

`eval/gate-ab/tests/test_chain_report.py`:

```python
import json, os, shutil, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import chain_report as cr


class Pure(unittest.TestCase):
    def test_step_failures(self):
        self.assertEqual(cr.step_failures({"solved": True, "regression_count": 0}, {"chain_regressions": 0}), 0)
        self.assertEqual(cr.step_failures({"solved": False, "regression_count": 2}, {"chain_regressions": 1}), 4)

    def test_step_failures_unknown_regression_count_is_none(self):
        self.assertIsNone(cr.step_failures({"solved": True, "regression_count": -1}, {"chain_regressions": 0}))
        self.assertIsNone(cr.step_failures({"solved": True, "regression_count": 0}, None))

    def test_gate_verdict(self):
        self.assertEqual(cr.gate_verdict(3, 1), "gate pays on chains")
        self.assertEqual(cr.gate_verdict(1, 1), "no gain")
        self.assertEqual(cr.gate_verdict(1, 2), "no gain")
        self.assertEqual(cr.gate_verdict(2, 1), "unclear")

    def test_erosion_rises(self):
        chains = [[0.0, 0.1, 0.2, 0.3], [0.0, 0.0, 0.0, 0.0], [0.1, 0.2, 0.2, 0.4], [0.0, 0.2, 0.1, 0.1]]
        self.assertEqual(cr.erosion_rises(chains, 0.05), (3, 4))
        self.assertEqual(cr.erosion_rises(chains, 0.35), (1, 4))   # must also end above the reference step 4
        self.assertEqual(cr.erosion_rises([[0.0, None, 0.1, None]], 0.0), (0, 0))  # no step-4 figure: not counted

    def test_item16_verdict(self):
        self.assertEqual(cr.item16_verdict(3, 4), "build item 16")
        self.assertEqual(cr.item16_verdict(2, 4), "do not build item 16")


class Main(unittest.TestCase):
    def test_report_written(self):
        d = tempfile.mkdtemp()
        try:
            tasks = ["a", "b"]
            for arm in ("u", "gs"):
                for rep in (1, 2):
                    for i, t in enumerate(tasks):
                        rd = os.path.join(d, "runs", "%s-%s-%d" % (t, arm, rep)); os.makedirs(rd)
                        json.dump(dict(solved=not (arm == "u" and i == 1), false_done=arm == "u" and i == 1, regression_count=0,
                                       wall_seconds=10, cost_usd=0.1, error=None), open(os.path.join(rd, "score.json"), "w"))
                        json.dump(dict(chain_regressions=0, erosion=dict(erosion=0.1 * i), error=None), open(os.path.join(rd, "chain.json"), "w"))
            json.dump([dict(task="a", erosion=0.0), dict(task="b", erosion=0.0)], open(os.path.join(d, "chain-reference-erosion.json"), "w"))
            text = cr.main(d, tasks)
            self.assertIn("u: failures 2", text)
            self.assertIn("gs: failures 0", text)
            self.assertIn("Gate: gate pays on chains", text)
            self.assertIn("false_done: b-u-1, b-u-2", text)
            self.assertTrue(os.path.exists(os.path.join(d, "chain-report.md")))
        finally:
            shutil.rmtree(d)
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd eval/gate-ab && python3 -m unittest tests.test_chain_report -v`
Expected: ERROR — `No module named 'chain_report'`.

- [ ] **Step 3: Implement `eval/gate-ab/chain_report.py`**

```python
#!/usr/bin/env python3
"""chain_report.py <root> <task>...: the chained-feature-work table and the pre-registered verdicts (spec 2026-10-11
chained feature work §4). Writes <root>/chain-report.md. Item 15 needs the transcripts; the report lists the false_done steps."""
import json, os, statistics, sys

ARMS = ("u", "gs")


def _load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def step_failures(score, chain):
    if chain is None or chain.get("chain_regressions") is None or score.get("regression_count", -1) < 0:
        return None
    return (0 if score.get("solved") else 1) + score["regression_count"] + chain["chain_regressions"]


def gate_verdict(fail_u, fail_gs):
    d = fail_u - fail_gs
    return "gate pays on chains" if d >= 2 else "no gain" if d <= 0 else "unclear"


def erosion_rises(chains, ref_last):
    counted = rising = 0
    for c in chains:
        if not c or c[0] is None or c[-1] is None:
            continue
        counted += 1
        if c[-1] > c[0] and c[-1] > ref_last:
            rising += 1
    return rising, counted


def item16_verdict(rising, counted):
    return "build item 16" if rising >= 3 else "do not build item 16"


def main(root, tasks):
    lines = ["# Chained feature work", "", "| arm | chain | step | task | solved | false_done | regressions | chain regressions | erosion | wall s | cost USD |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    fails = {a: 0 for a in ARMS}; unknown = []; false_done = []; ero_chains = []; walls = {a: [] for a in ARMS}; costs = {a: [] for a in ARMS}
    reps = sorted({int(n.rsplit("-", 1)[1]) for n in os.listdir(os.path.join(root, "runs")) if n.rsplit("-", 1)[-1].isdigit()})
    for arm in ARMS:
        for rep in reps:
            chain_ero = []
            for k, t in enumerate(tasks, 1):
                rid = "%s-%s-%d" % (t, arm, rep)
                s = _load(os.path.join(root, "runs", rid, "score.json")) or {}
                c = _load(os.path.join(root, "runs", rid, "chain.json"))
                f = step_failures(s, c) if s and s.get("error") is None else None
                if f is None:
                    unknown.append(rid)
                else:
                    fails[arm] += f
                if s.get("false_done"):
                    false_done.append(rid)
                e = ((c or {}).get("erosion") or {}).get("erosion")
                chain_ero.append(e)
                if s.get("wall_seconds") is not None:
                    walls[arm].append(s["wall_seconds"]); costs[arm].append(s.get("cost_usd") or 0.0)
                lines.append("| %s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                    arm, rep, k, t, s.get("solved"), s.get("false_done"), s.get("regression_count"),
                    (c or {}).get("chain_regressions"), e, s.get("wall_seconds"),
                    None if s.get("cost_usd") is None else round(s["cost_usd"], 3)))
            ero_chains.append(chain_ero)
    ref = _load(os.path.join(root, "chain-reference-erosion.json")) or []
    ref_last = ref[-1]["erosion"] if ref else 0.0
    rising, counted = erosion_rises(ero_chains, ref_last)
    lines += ["", "u: failures %d" % fails["u"], "gs: failures %d" % fails["gs"],
              "Gate: %s (u - gs = %d)" % (gate_verdict(fails["u"], fails["gs"]), fails["u"] - fails["gs"]),
              "Item 16: %s (erosion rising in %d of %d chains; reference step %d erosion %s)" % (
                  item16_verdict(rising, counted), rising, counted, len(ref), ref_last),
              "Item 15: read the transcripts of false_done: %s" % (", ".join(false_done) or "none"),
              "Unscored or errored steps: %s" % (", ".join(unknown) or "none")]
    for a in ARMS:
        if walls[a]:
            lines.append("%s: median wall %s s, median cost USD %.3f" % (a, statistics.median(walls[a]), statistics.median(costs[a])))
    text = "\n".join(lines) + "\n"
    with open(os.path.join(root, "chain-report.md"), "w") as fh:
        fh.write(text)
    return text


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: chain_report.py <root> <task>...")
    print(main(sys.argv[1], sys.argv[2:]), end="")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd eval/gate-ab && python3 -m unittest discover -s tests -v 2>&1 | tail -3`
Expected: all tests OK (existing + new).

- [ ] **Step 5: Commit**

```bash
git add eval/gate-ab/chain_report.py eval/gate-ab/tests/test_chain_report.py
git commit -m "gate-ab: chain_report.py — chain table and the pre-registered verdicts

Claude-Session: https://claude.ai/code/session_01NYhZujY9dqgFF2eCQLXzKw"
```

---

### Task 7: README, live validation, campaign, write-up

**Files:**
- Modify: `eval/gate-ab/README.md` (a "Chained feature work" section)
- Create (scala-coding-guidelines): `raw/llm-scala-fusion/2026-10-11-local-chained-feature-work.md` (date = run day)
- Modify (scala-coding-guidelines): `wiki/llm-scala-fusion/roadmap-more-scala-less-llm.md` (item 14 status; items 15, 16 per rules), `wiki/index.md`, `wiki/log.md`

- [ ] **Step 1: README section**

Add to `eval/gate-ab/README.md`:

```markdown
## Chained feature work (spec 2026-10-11)

Four feature requests land one after another on the same tree: `GA_CHAIN="fr-pan fr-exclusive-solo fr-mode-leds fr-tuning"`.
Step k starts from step k-1's `final-tree.tar.gz` (`GA_SEED_TREE`), as a fresh repository; a failed step does not stop the chain.
After each step `chaincheck.py` re-runs every earlier step's hidden spec on the tree (`chain.json`: pass / fail / na) and records
the erosion figure (`erosion.py` + `erosion.scala`: share of CC x sqrt(SLOC) mass in methods with CC > 10, changed main files).
`prepare-chain.sh` validates the chain on HEAD + the reference patches and writes the reference erosion line.
Re-running a step redoes the rest of its chain. `chain_report.py <root> <task>...` prints the table and the verdicts.

    GA_ROOT=~/gate-eval-chain sh warm-cache.sh
    GA_ROOT=~/gate-eval-chain python3 score.py --baseline
    GA_ROOT=~/gate-eval-chain GA_CHAIN="fr-pan fr-exclusive-solo fr-mode-leds fr-tuning" GA_ARMS="u gs" GA_REPS="1 2" sh campaign.sh
    python3 chain_report.py ~/gate-eval-chain fr-pan fr-exclusive-solo fr-mode-leds fr-tuning
```

Commit with the README path only.

- [ ] **Step 2: Live preparation**

Run (each in turn, reading output):

```bash
cd eval/gate-ab
GA_ROOT=~/gate-eval-chain sh warm-cache.sh
GA_ROOT=~/gate-eval-chain python3 score.py --baseline
for t in fr-pan fr-exclusive-solo fr-mode-leds fr-tuning; do GA_ROOT=~/gate-eval-chain sh prepare.sh $t; done
GA_ROOT=~/gate-eval-chain sh prepare-chain.sh fr-pan fr-exclusive-solo fr-mode-leds fr-tuning
cat ~/gate-eval-chain/chain-reference-erosion.json
```

Expected: every `validation.txt` all yes; `patches_apply=yes`, `reference_passes_all=yes`; a 4-entry reference erosion line. On a `no`, read the log named in the output; a failing reference is a plan defect → ruling, not a code change to skreeep2.

- [ ] **Step 3: Live smoke of the erosion script on a real tree**

Run: `python3 eval/gate-ab/erosion.py ~/gate-eval-chain/head ~/gate-eval-chain/head` → Expected `{"methods": 0, "total_mass": 0.0, "erosion": 0.0}`; and on a scratch copy of head with `control/src/.../MixerMode.scala` touched (append a blank line) → Expected `methods` > 0 and no error.

- [ ] **Step 4: Campaign (16 runs, same day)**

Run in the background:

```bash
cd eval/gate-ab && GA_ROOT=~/gate-eval-chain GA_CHAIN="fr-pan fr-exclusive-solo fr-mode-leds fr-tuning" GA_ARMS="u gs" GA_REPS="1 2" sh campaign.sh > ~/gate-eval-chain/campaign.out 2>&1
```

Expected: 16 `exit=` lines and 16 `chain ... regressions=` lines in `~/gate-eval-chain/campaign.log`, no `error` in any score.json / chain.json. Re-run the same command to resume after an interruption.

- [ ] **Step 5: Report and audit**

Run: `python3 eval/gate-ab/chain_report.py ~/gate-eval-chain fr-pan fr-exclusive-solo fr-mode-leds fr-tuning`

Audit as in item 11: contamination and tampering flags (read the diffs), gate blocks in `gs`, and for every false_done step the transcript route (was the edit through an interpreter or sed, which the tool-policy rule blocks in `gs` only, or another route?). Record the item 15 verdict from that reading.

- [ ] **Step 6: Write-up (scala-coding-guidelines)**

Raw file `raw/llm-scala-fusion/<run-date>-local-chained-feature-work.md` in the style of `2026-10-11-local-scala-interp-edit-rule.md` (Source with template commit and run root, Why, Chain, Arms, pre-registered rules, Results table copied from `chain-report.md`, decision, mechanism, audit, limits). Then the roadmap: item 14 gets `> **Status: Measured** (<date>)` with the verdicts; items 15 and 16 get `> **Status: ...**` per the rules (Built → a follow-up plan; otherwise `Not pursued` with the reason). Index row and log entry; run `python3 ~/.claude/skills/karpathy-llm-wiki/scripts/check_evidence.py .` and fix any mismatch. Commit with explicit paths.
```
