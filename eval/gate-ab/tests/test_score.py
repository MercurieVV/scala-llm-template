import json, os, shutil, subprocess, sys, tempfile, unittest, pathlib
HERE = pathlib.Path(__file__).parent
sys.path.insert(0, str(HERE.parent))
import score

FX = HERE / "fixtures" / "transcripts"

def lines(name): return (FX / name).read_text().splitlines()

def bash(cmd): return {"name": "Bash", "input": {"command": cmd}, "result_text": "", "is_error": False, "turn": 1}

class Transcript(unittest.TestCase):
    def test_clean_metrics(self):
        t = score.parse_transcript(lines("clean.jsonl"))
        self.assertEqual(t["turns"], 2); self.assertAlmostEqual(t["cost_usd"], 0.42)
        self.assertEqual((t["input_tokens"], t["output_tokens"], t["cache_read_tokens"]), (1000, 200, 5000))
    def test_empty_transcript(self):
        t = score.parse_transcript([])
        self.assertIsNone(t["turns"]); self.assertEqual(t["tool_calls"], [])
    def test_empty_fixture(self):
        t = score.parse_transcript(lines("empty.jsonl"))
        self.assertFalse(t["has_result"])
    def test_first_clean_compile(self):
        t = score.parse_transcript(lines("clean.jsonl"))
        self.assertEqual(score.first_clean_compile(t["tool_calls"]), 1)
    def test_compile_with_error_not_clean(self):
        c = bash("./mill signals.compile"); c["result_text"] = "[error] boom"
        self.assertIsNone(score.first_clean_compile([c]))
    def test_texts_collect_all_sources(self):
        lns = [json.dumps({"type": "system", "subtype": "hook_response", "output": "hook says hi"}),
               json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": "Stop hook feedback: x"}]}})]
        t = score.parse_transcript(lns + lines("clean.jsonl"))
        self.assertIn("hook says hi", t["texts"]); self.assertIn("Stop hook feedback: x", t["texts"])
        self.assertIn("Done.", t["texts"]); self.assertIn("compiling 3 Scala sources\n", t["texts"])

class Blocks(unittest.TestCase):
    def test_counts_by_hook(self):
        t = score.parse_transcript(lines("blocked.jsonl"))
        b = score.gate_blocks(t["tool_calls"], t["texts"])
        self.assertEqual(b.get("tool-policy"), 1); self.assertEqual(b.get("semantic-guard-sealed"), 1)
    def test_turn_end_from_text(self):
        b = score.gate_blocks([], ["Stop hook feedback: fix it", "turn-end gate: BLOCKED", "fine"])
        self.assertEqual(b, {"turn-end": 2})
    def test_same_block_in_adjacent_events_counted_once(self):
        ev = lambda t: json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": t}]}})
        t = score.parse_transcript([ev("Stop hook feedback: x"), ev("Stop hook feedback: x")])
        self.assertEqual(score.gate_blocks([], t["hook_texts"]), {"turn-end": 1})
    def test_same_text_duplicated_inside_one_system_event_counted_once(self):
        t = score.parse_transcript([json.dumps({"type": "system", "output": "Stop hook feedback: x", "stdout": "Stop hook feedback: x"})])
        self.assertEqual(score.gate_blocks([], t["hook_texts"]), {"turn-end": 1})
    def test_identical_blocks_in_separate_turns_counted_twice(self):
        ev = lambda t: json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": t}]}})
        asst = json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "retrying"}]}})
        t = score.parse_transcript([ev("Stop hook feedback: x"), asst, ev("Stop hook feedback: x")])
        self.assertEqual(score.gate_blocks([], t["hook_texts"]), {"turn-end": 2})
    def test_assistant_and_tool_result_text_not_counted(self):
        lns = [json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "Stop hook feedback: I quote it"}]}}),
               json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "a", "name": "Bash", "input": {"command": "echo"}}]}}),
               json.dumps({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "a", "content": "Stop hook feedback: in output"}]}}),
               json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": "Stop hook feedback: real"}]}})]
        t = score.parse_transcript(lns)
        self.assertEqual(score.gate_blocks(t["tool_calls"], t["hook_texts"]), {"turn-end": 1})

class Contamination(unittest.TestCase):
    RUN = "/Users/someone/gate-eval/runs/noise-g-1"
    def flagged(self, cmd, run=RUN):
        return score.contamination([bash(cmd)], run)
    def test_outside_read_flagged_tmp_allowed(self):
        t = score.parse_transcript(lines("contaminated.jsonl"))
        c = score.contamination(t["tool_calls"], self.RUN)
        self.assertEqual(len(c), 1); self.assertIn("IdeaProjects/skreeep2", c[0])
    def test_inside_run_dir_allowed(self):
        calls = [{"name": "Read", "input": {"file_path": "/r/run/repo/a.scala"}, "result_text": "", "is_error": False, "turn": 1}]
        self.assertEqual(score.contamination(calls, "/r/run"), [])
    def test_relative_repo_path_ok(self):
        self.assertEqual(self.flagged("cat src/a.scala ./b.scala"), [])
    def test_relative_base_path_flagged(self):
        c = self.flagged("cat ../../../base/noise/hidden/x.scala")
        self.assertEqual(c, ["Bash: /Users/someone/gate-eval/base/noise/hidden/x.scala"])
    def test_relative_in_read_tool(self):
        calls = [{"name": "Read", "input": {"file_path": "../../../head/a"}, "result_text": "", "is_error": False, "turn": 1}]
        self.assertEqual(len(score.contamination(calls, self.RUN)), 1)
    def test_chmod_on_base(self):
        c = self.flagged("chmod -R 755 /Users/someone/gate-eval/base")
        self.assertEqual(c, ["Bash: /Users/someone/gate-eval/base"])
    def test_chmod_outside_run_even_in_tmp(self):
        c = self.flagged("chmod 755 /tmp/x")
        self.assertEqual(len(c), 1); self.assertTrue(c[0].endswith("/tmp/x"))
    def test_chmod_inside_run_ok(self):
        self.assertEqual(self.flagged("chmod +x ./mill"), [])
    def test_sibling_run_dir(self):
        c = self.flagged("ls /Users/someone/gate-eval/runs/noise-u-1/repo")
        self.assertEqual(len(c), 1); self.assertIn("noise-u-1", c[0])
    def test_sibling_run_dir_relative(self):
        self.assertEqual(len(self.flagged("ls ../../noise-u-1/repo")), 1)
    def test_skreeep2_path(self):
        c = self.flagged("grep -r foo /Users/viktorskalinins/IdeaProjects/skreeep2/signals")
        self.assertEqual(len(c), 1)
    def test_git_c_outside(self):
        self.assertEqual(len(self.flagged("git -C /Users/viktorskalinins/IdeaProjects/skreeep2 log")), 1)
    def test_protected_even_under_allowed_prefix(self):
        os.environ["GA_ROOT"] = "/tmp/ga-root"
        try:
            self.assertEqual(len(self.flagged("cat /tmp/ga-root/base/x")), 1)
        finally:
            del os.environ["GA_ROOT"]
    def test_mcp_tool_leaves_scanned(self):
        calls = [{"name": "mcp__scala-semantic__set_workspace_root", "input": {"root": "../../../head"}, "result_text": "", "is_error": False, "turn": 1},
                 {"name": "mcp__x__y", "input": {"nested": {"uri": "file:///Users/viktorskalinins/IdeaProjects/skreeep2/a.scala"}}, "result_text": "", "is_error": False, "turn": 2}]
        self.assertEqual(len(score.contamination(calls, self.RUN)), 2)
    def test_written_content_not_scanned(self):
        calls = [{"name": "Write", "input": {"file_path": "x.txt", "content": "see /etc/foo and /Users/zzz/q"}, "result_text": "", "is_error": False, "turn": 1}]
        self.assertEqual(score.contamination(calls, self.RUN), [])
    def test_toolchain_prefixes_allowed(self):
        home = os.path.expanduser("~")
        self.assertEqual(self.flagged("ls %s/.mill /Library/Java/x /System/y /etc/hosts" % home), [])
    def test_dev_null_and_urls_ok(self):
        self.assertEqual(self.flagged("curl https://x.org/a/b 2>/dev/null"), [])

class RealGated(unittest.TestCase):
    """Fixture = verbatim events from the smoke run midi-synth-g-9 (real hook texts)."""
    def test_real_hook_texts_counted(self):
        t = score.parse_transcript(lines("real-gated.jsonl"))
        self.assertEqual(score.gate_blocks(t["tool_calls"], t["hook_texts"]), {"ScalaSemantic": 1, "turn-end": 1})
    def test_real_scala_semantic_write_body_not_contamination(self):
        t = score.parse_transcript(lines("real-gated.jsonl"))
        self.assertEqual(score.contamination(t["tool_calls"], "/Users/someone/gate-eval/runs/midi-synth-g-9"), [])

class EnvLeak(unittest.TestCase):
    """Ruling 20. Fixtures: init + hook events verbatim from the smoke runs midi-synth-{g,u}-9 (before the fix; long hook
    outputs truncated, user name replaced) and from a `--setting-sources project --strict-mcp-config` probe."""
    def test_real_leaked_ungated(self):
        t = score.parse_transcript(lines("real-init-leaked-u.jsonl"))
        leaks = score.env_leaks(t, "u")
        self.assertEqual(len(leaks), 3, leaks)
        self.assertIn("playwright", leaks[0]); self.assertIn("caveman", leaks[1]); self.assertIn("SessionStart", leaks[2])
    def test_real_leaked_gated_hooks_allowed(self):
        t = score.parse_transcript(lines("real-init-leaked-g.jsonl"))
        leaks = score.env_leaks(t, "g")
        self.assertEqual(len(leaks), 2, leaks)
        self.assertTrue(leaks[0].startswith("mcp_servers=")); self.assertTrue(leaks[1].startswith("plugins="))
    def test_isolated_init_clean_in_both_arms(self):
        t = score.parse_transcript(lines("real-init-isolated.jsonl"))
        self.assertEqual(score.env_leaks(t, "u"), []); self.assertEqual(score.env_leaks(t, "g"), [])
    def test_hook_event_leaks_only_ungated(self):
        hook = json.dumps({"type": "system", "subtype": "hook_started", "hook_name": "PreToolUse:Bash", "hook_event": "PreToolUse"})
        t = score.parse_transcript(lines("real-init-isolated.jsonl") + [hook])
        self.assertEqual(score.env_leaks(t, "g"), []); self.assertEqual(score.env_leaks(t, "u"), ["hooks=PreToolUse:Bash"])
    def test_missing_init_with_result(self):
        t = score.parse_transcript(lines("clean.jsonl"))
        self.assertEqual(score.env_leaks(t, "u"), ["no init event"])
        self.assertEqual(score.env_leaks(score.parse_transcript([]), "u"), [])
    def test_init_event_not_hook_text(self):
        t = score.parse_transcript(lines("real-init-isolated.jsonl"))
        self.assertEqual(t["hook_texts"], []); self.assertNotIn("scala-semantic", t["texts"])

class ContaminationHardening(unittest.TestCase):
    RUN = "/Users/someone/gate-eval/runs/noise-g-1"
    def setUp(self):
        self.saved = dict(os.environ)
        os.environ["HOME"] = "/Users/someone"; os.environ.pop("CLAUDE_CONFIG_DIR", None); os.environ.pop("GA_ROOT", None)
    def tearDown(self):
        os.environ.clear(); os.environ.update(self.saved)
    def flagged(self, cmd):
        return score.contamination([bash(cmd)], self.RUN)
    def tool(self, name, **inp):
        return score.contamination([{"name": name, "input": inp, "result_text": "", "is_error": False, "turn": 1}], self.RUN)
    # I1: heredoc bodies and comment/glob tokens
    def test_heredoc_scala_with_comments_not_flagged(self):
        cmd = ("cat > signals/src/A.scala <<'EOF'\n/** Doc: see /Users/zzz/q and /etc/x.\n  * @param p /opt/thing\n  */\n"
               "// https://example.org/a and /Users/elsewhere/b\nobject A { val p = \"/Users/q/r\" } /* c */\nEOF\n./mill signals.compile")
        self.assertEqual(self.flagged(cmd), [])
    def test_heredoc_unquoted_and_dash(self):
        self.assertEqual(self.flagged("cat <<EOF >a.txt\n/Users/x/y\nEOF"), [])
        self.assertEqual(self.flagged("cat <<-'END' >a.txt\n\t/Users/x/y\n\tEND\nls"), [])
    def test_heredoc_target_outside_still_flagged(self):
        c = self.flagged("cat <<EOF > /Users/viktorskalinins/IdeaProjects/skreeep2/x\nbody\nEOF")
        self.assertEqual(len(c), 1, c)
    def test_here_string_is_not_heredoc(self):
        self.assertEqual(len(self.flagged("grep x <<< foo\ncat /Users/viktorskalinins/IdeaProjects/skreeep2/a")), 1)
    def test_comment_tokens_ignored_outside_heredoc(self):
        self.assertEqual(self.flagged("echo // not a path /* nor this */"), [])
    def test_glob_tokens(self):
        self.assertEqual(self.flagged("ls **/*.scala src/*/x"), [])
        self.assertEqual(len(self.flagged("ls /Users/viktorskalinins/IdeaProjects/skreeep2/*.scala")), 1)
    # Ruling 24: only a here-doc redirected into a file is written content; a script here-doc is scanned
    def test_python_heredoc_script_flagged(self):
        cmd = "python3 - <<'EOF'\nimport os\nfor d in os.walk('/Users/viktorskalinins/IdeaProjects/skreeep2'): print(d)\nEOF"
        self.assertEqual(len(self.flagged(cmd)), 1, self.flagged(cmd))
    def test_sh_heredoc_script_flagged(self):
        cmd = "sh <<'EOF'\ncat /Users/viktorskalinins/IdeaProjects/skreeep2/signals/src/A.scala\nEOF"
        self.assertEqual(len(self.flagged(cmd)), 1, self.flagged(cmd))
    def test_script_heredoc_comments_still_ignored(self):
        self.assertEqual(self.flagged("python3 - <<'EOF' 2>/dev/null\n// x /** y */ **/*.scala\nprint(1)\nEOF"), [])
    def test_heredoc_into_file_via_append_and_tee(self):
        self.assertEqual(self.flagged("cat >> notes.txt <<EOF\n/Users/x/y\nEOF"), [])
        self.assertEqual(self.flagged("tee a.scala <<'EOF' >/dev/null\n/Users/x/y\nEOF"), [])
        self.assertEqual(self.flagged("cat <<'EOF' | tee a.scala\n/Users/x/y\nEOF"), [])
    # bare `/`: root only as a standalone argument of a walker in its own pipeline segment
    def test_bare_slash_arithmetic_next_to_walker(self):
        self.assertEqual(self.flagged("echo $((3 / 4)); ls"), [])
        self.assertEqual(self.flagged('awk "{print $1 / 2}" f.txt | head'), [])
        self.assertEqual(self.flagged('grep -E "/ " src/a.txt'), [])
    def test_bare_slash_root_in_segment(self):
        self.assertEqual(self.flagged("cd src && du -sh / | sort"), ["Bash: /"])
        self.assertEqual(self.flagged("echo hi; grep -r Spec / 2>/dev/null"), ["Bash: /"])
    def test_grep_pattern_is_not_a_path(self):
        self.assertEqual(self.tool("Grep", pattern="/\\*\\*", path="signals"), [])
        self.assertEqual(self.tool("Grep", pattern="/Users/x", path="."), [])
    # I2: roots and ancestors of protected paths
    def test_find_from_root(self):
        self.assertEqual(self.flagged("find / -name MidiSynthSpec.scala"), ["Bash: /"])
    def test_bare_slash_as_arithmetic_not_root(self):
        self.assertEqual(self.flagged('python3 -c "print(4 / 2)"; echo $((6 / 3))'), [])
    def test_grep_home(self):
        for h in ("~", "$HOME", "${HOME}", "~/"):
            self.assertEqual(self.flagged("grep -r MidiSynthSpec %s" % h), ["Bash: /Users/someone"], h)
    def test_tilde_user(self):
        root_home = os.path.realpath(os.path.expanduser("~root"))
        self.assertEqual(self.flagged("ls ~root"), ["Bash: %s" % root_home])
        self.assertEqual(self.flagged("ls ~nosuchuser4711"), [])
    def test_glob_and_grep_tool_root(self):
        self.assertEqual(self.tool("Glob", pattern="**/MidiSynthSpec.scala", path="/"), ["Glob: /"])
        self.assertEqual(self.tool("Grep", pattern="MidiSynth", path="/Users/someone/gate-eval"), ["Grep: /Users/someone/gate-eval"])
    def test_ancestor_under_allowed_prefix(self):
        os.environ["GA_ROOT"] = "/tmp/ga-root"
        c = score.contamination([bash("find /tmp -name '*Spec.scala'")], "/tmp/ga-root/runs/noise-g-1")
        self.assertEqual(c, ["Bash: %s" % os.path.realpath("/tmp")])
    def test_runs_parent_is_ancestor_of_other_runs(self):
        self.assertEqual(self.flagged("ls ../.."), ["Bash: /Users/someone/gate-eval/runs"])
    def test_repo_searches_not_flagged(self):
        self.assertEqual(self.flagged("rg -n MidiSynth ./ && find ./signals -name '*.scala' && ls .. ../repo"), [])
    def test_claude_projects_protected(self):
        c = self.flagged("cat ~/.claude/projects/-Users-someone-gate-eval-runs-noise-g-2-repo/x.jsonl")
        self.assertEqual(len(c), 1, c)
        self.assertEqual(len(self.flagged("ls ~/.claude")), 1)
    def test_own_memory_dir_allowed(self):
        self.assertEqual(self.tool("Write", file_path="/Users/someone/.claude/projects/-Users-someone-gate-eval-runs-noise-g-1-repo/memory/m.md",
                                   content="x"), [])
    # I5: holdout material inside the run dir
    def test_holdout_inside_run_dir(self):
        self.assertEqual(self.tool("Read", file_path=self.RUN + "/holdout/HSpec.scala"), ["Read: %s/holdout/HSpec.scala" % self.RUN])
        self.assertEqual(self.flagged("cat ../holdout/HSpec.scala"), ["Bash: %s/holdout/HSpec.scala" % self.RUN])
        self.assertEqual(self.flagged("ls out-holdout/holdout"), ["Bash: %s/repo/out-holdout/holdout" % self.RUN])
        self.assertEqual(self.flagged("tail .dsh/.state/holdout.log"), ["Bash: %s/repo/.dsh/.state/holdout.log" % self.RUN])
    def test_holdout_bare_name_from_repo(self):
        self.assertEqual(self.flagged("ls -la out-holdout"), ["Bash: %s/repo/out-holdout" % self.RUN])

class Weaver(unittest.TestCase):
    def test_counts(self):
        log = "\x1b[32m+ \x1b[0ma passes 1ms\n\x1b[31m- \x1b[0mb fails 2ms\n+ c 3ms\n"
        self.assertEqual(score.weaver_counts(log), (2, 1, True))
    def test_anchoring_and_duration(self):
        log = "+ no duration here\n  + indented 1ms\n- also no duration\ndiff - x\n+ ok 4ms\n- bad 1s\n"
        self.assertEqual(score.weaver_counts(log), (1, 1, True))
    def test_compile_failure(self):
        self.assertEqual(score.weaver_counts("[error] x.test.compile Compilation failed\n"), (0, 0, False))

class Tampering(unittest.TestCase):
    def test_modified_flagged_new_ignored(self):
        diff = ("diff --git a/x/test/src/A.scala b/x/test/src/A.scala\nindex 1..2 100644\n"
                "diff --git a/x/test/src/B.scala b/x/test/src/B.scala\nnew file mode 100644\n"
                "diff --git a/x/src/C.scala b/x/src/C.scala\nindex 1..2 100644\n")
        self.assertEqual(score.tampering(diff), ["x/test/src/A.scala"])
    def test_deleted_flagged(self):
        diff = "diff --git a/x/test/src/A.scala b/x/test/src/A.scala\ndeleted file mode 100644\n"
        self.assertEqual(score.tampering(diff), ["x/test/src/A.scala"])

class Rename(unittest.TestCase):
    def test_rename_out_of_test_dir_flagged(self):
        diff = ("diff --git a/x/test/src/A.scala b/x/src/A.scala\nsimilarity index 100%\n"
                "rename from x/test/src/A.scala\nrename to x/src/A.scala\n")
        self.assertEqual(score.tampering(diff), ["x/test/src/A.scala"])
    def test_build_edits(self):
        diff = ("diff --git a/build.mill b/build.mill\nindex 1..2\ndiff --git a/x/package.mill b/x/package.mill\nnew file mode 100644\n"
                "diff --git a/x/src/A.scala b/x/src/A.scala\nindex 1..2\n")
        self.assertEqual(score.build_edits(diff), ["build.mill", "x/package.mill"])

class Hardcoding(unittest.TestCase):
    def test_literal_from_spec_in_src_plus_line(self):
        spec = 'expect(f(3) == 2039.0)\nexpect(name == "kick-drum")'
        diff = 'diff --git a/s/src/N.scala b/s/src/N.scala\n+  val p = 2039.0\n+  val n = "kick-drum"\n-  old 2039.0\n'
        self.assertEqual(sorted(score.hardcoding(diff, spec)), ['"kick-drum"', "2039.0"])
    def test_test_dirs_and_minus_lines_ignored(self):
        spec = 'expect(f == 2039.0)'
        diff = 'diff --git a/s/test/src/N.scala b/s/test/src/N.scala\n+  val p = 2039.0\ndiff --git a/s/src/M.scala b/s/src/M.scala\n-  old 2039.0\n'
        self.assertEqual(score.hardcoding(diff, spec), [])

class Verdict(unittest.TestCase):
    def test_solved_requires_everything(self):
        base = dict(hidden_compiled=True, hidden_passed=5, hidden_failed=0, holdout_passed=True, regressions=[], timed_out=False)
        self.assertTrue(score.is_solved(**base))
        self.assertFalse(score.is_solved(**{**base, "hidden_compiled": False}))
        self.assertFalse(score.is_solved(**{**base, "hidden_passed": 0}))
        self.assertFalse(score.is_solved(**{**base, "regressions": ["control.test"]}))
        self.assertFalse(score.is_solved(**{**base, "timed_out": True}))
    def test_false_done(self):
        self.assertTrue(score.is_false_done(solved=False, timed_out=False, exit_code=0))
        self.assertFalse(score.is_false_done(solved=False, timed_out=True, exit_code=124))
        self.assertFalse(score.is_false_done(solved=True, timed_out=False, exit_code=0))

class Parsers(unittest.TestCase):
    def test_suite_fq(self):
        spec = "package com.a.b\n\nimport x\n\nobject FooSpec extends SimpleIOSuite {\n}\n"
        self.assertEqual(score.suite_fq(spec), "com.a.b.FooSpec")
        self.assertIsNone(score.suite_fq("class X"))
    def test_hidden_counts_only_that_suite(self):
        log = (HERE / "fixtures" / "mill" / "hidden-cut.txt").read_text()
        self.assertEqual(score.hidden_counts(log, "com.github.mercurievv.skreeep2.plugin.MidiSynthSpec"), (0, 1, True))
        self.assertEqual(score.hidden_counts(log, "com.github.mercurievv.skreeep2.plugin.HostEventsSpec"), (2, 0, True))
        self.assertEqual(score.hidden_counts(log, "com.nope.Spec"), (0, 0, True))
    MODS = ["control.test", "plugin.test", "core.test", "bench.test"]
    ALL = ["core", "backpressure", "control", "plugin", "bench"]
    def test_parse_mill_failures_real_format(self):
        r = score.parse_mill_failures((HERE / "fixtures" / "mill" / "regress-failed.txt").read_text(), self.MODS, self.ALL)
        self.assertEqual(r["tests"], {"control.test", "plugin.test"}); self.assertEqual(r["compile"], {"<compile:core>"})
        self.assertEqual((r["other"], r["failed"]), ([], 4))
    def test_module_without_test_module_failing_to_compile(self):
        r = score.parse_mill_failures("[error] backpressure.compile task failed\n", self.MODS, self.ALL)
        self.assertEqual((r["compile"], r["other"]), ({"<compile:backpressure>"}, []))
    def test_build_file_error(self):
        for line in ("[error] build.mill:12:3: not found: value x", "[error] /r/x/package.mill:7:1: boom"):
            r = score.parse_mill_failures(line + "\n", self.MODS, self.ALL)
            self.assertEqual((r["compile"], r["other"]), ({"<build>"}, []), line)
    def test_real_broken_build_regression_log(self):
        r = score.parse_mill_failures((HERE / "fixtures" / "mill" / "build-broken-regress.txt").read_text(), self.MODS, self.ALL)
        self.assertEqual((r["tests"], r["compile"], r["other"]), (set(), {"<build>"}, []))
    def test_build_broken_detects_real_meta_build_failures(self):
        for f in ("build-broken-resolve.txt", "build-broken-package-resolve.txt", "build-broken-regress.txt"):
            self.assertTrue(score.build_broken((HERE / "fixtures" / "mill" / f).read_text()), f)
        self.assertTrue(score.build_broken("[error] compile Compilation failed\n"))
        self.assertTrue(score.build_broken("[2] [error] build.mill:9:19\n"))
        for f in ("regress-failed.txt", "baseline-excerpt.txt", "hidden-cut.txt"):
            self.assertFalse(score.build_broken((HERE / "fixtures" / "mill" / f).read_text()), f)
        self.assertFalse(score.build_broken("resolve exploded\n"))
    def test_compilation_failed_without_a_module(self):
        r = score.parse_mill_failures("[error] Compilation failed\n", self.MODS, self.ALL)
        self.assertEqual((r["compile"], r["other"]), ({"<compile>"}, []))
    def test_parse_mill_failures_unattributed_error_line(self):
        r = score.parse_mill_failures("[error] java.lang.OutOfMemoryError: Java heap space\n[error] 1 tests failed:\n", self.MODS, self.ALL)
        self.assertEqual((r["tests"], r["compile"]), (set(), set()))
        self.assertEqual(r["other"], ["java.lang.OutOfMemoryError: Java heap space"])
    def test_parse_mill_failures_clean(self):
        r = score.parse_mill_failures("+ a 1ms\n[10/10] mill x 3s\n", self.MODS, self.ALL)
        self.assertEqual((r["tests"], r["compile"], r["other"], r["failed"]), (set(), set(), [], 0))
    EXCERPT = (HERE / "fixtures" / "mill" / "baseline-excerpt.txt").read_text()
    def test_real_baseline_excerpt_counts_one_failure(self):
        self.assertEqual(score.weaver_counts(self.EXCERPT), (12, 1, True))
        self.assertEqual(score.hidden_counts(self.EXCERPT, "com.github.mercurievv.skreeep2.UnderrunSpec"), (4, 1, True))
    def test_real_baseline_excerpt_failures_attributed(self):
        r = score.parse_mill_failures(self.EXCERPT, ["bench.test", "control.midi.test"], ["bench"])
        self.assertEqual(r["tests"], {"bench.test"}); self.assertEqual((r["compile"], r["other"]), (set(), []))
    def test_failures_block_not_counted(self):
        log = "Running Test Class a.B\n+ ok 1ms\n- bad 1ms\n*****FAILURES*****\n- bad 1ms\nRunning Test Class a.C\n+ fine 1ms\n"
        self.assertEqual(score.weaver_counts(log), (2, 1, True))
        self.assertEqual(score.hidden_counts(log, "a.B"), (1, 1, True))
    def test_suite_passes_and_module_attribution(self):
        p = score.suite_passes(self.EXCERPT)
        self.assertEqual(p, {"com.github.mercurievv.skreeep2.UnderrunSpec": 4,
                             "com.github.mercurievv.skreeep2.control.midi.ControlSurfaceSpec": 3,
                             "com.github.mercurievv.skreeep2.control.midi.McuSpec": 2,
                             "com.github.mercurievv.skreeep2.wiring.WiringDetailsSpec": 3})
        by = {"bench.test": ["com.github.mercurievv.skreeep2.UnderrunSpec"],
              "control.midi.test": ["com.github.mercurievv.skreeep2.control.midi.ControlSurfaceSpec",
                                    "com.github.mercurievv.skreeep2.control.midi.McuSpec"]}
        self.assertEqual(score.module_passes(p, by), {"bench.test": 4, "control.midi.test": 5})
    def test_truncated_suite_names(self):
        log = "Running Test Class a.b.LongNameSp...\n+ x 1ms\n"
        self.assertEqual(score.hidden_counts(log, "a.b.LongNameSpec"), (1, 0, True))
        self.assertEqual(score.module_passes(score.suite_passes(log), {"m.test": ["a.b.LongNameSpec"]}), {"m.test": 1})
    def test_other_suites(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d) / "signals" / "test" / "src" / "pk"
            p.mkdir(parents=True)
            (p / "NoiseSpec.scala").write_text("package pk\nobject NoiseSpec extends SimpleIOSuite\n")
            (p / "Other.scala").write_text("package pk\nobject OtherSpec extends IOSuite\nobject Helper\n")
            self.assertEqual(score.other_suites(d, "signals.test", "pk.NoiseSpec"), ["pk.OtherSpec"])

FAKE_MILL = r"""#!/usr/bin/env python3
import json, os, sys, time
a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps({"cwd": os.getcwd(), "args": a, "out": os.environ.get("MILL_OUTPUT_DIR"), "holdout": os.environ.get("DSH_HOLDOUT_DIR")}) + "\n")
tree = "score-tree" in os.getcwd()
if tree and os.environ.get("FAKE_BUILD_BROKEN"):  # real Mill output for a broken build.mill: every command fails before any task
    sys.stdout.write(open(os.environ["FAKE_BUILD_BROKEN"]).read()); sys.exit(1)
if "resolve" in a:
    if os.environ.get("FAKE_RESOLVE_FAIL"):
        print("resolve exploded"); sys.exit(1)
    if "__:Module" in a:
        if os.environ.get("FAKE_ALL_RESOLVE_FAIL"): print("resolve exploded"); sys.exit(1)
        print("\n".join(os.environ.get("FAKE_ALL_MODULES", "core,signals,control,backpressure").split(","))); sys.exit(0)
    print("\n".join(os.environ.get("FAKE_MODULES", "signals.test,holdout.test,control.test,backend.opencl.test,bench.test").split(","))); sys.exit(0)
if a[-1] == "holdout.test":
    if not os.path.isdir(os.environ.get("DSH_HOLDOUT_DIR", "")): sys.exit(9)
    hm = os.environ.get("FAKE_HOLDOUT", "pass")
    if hm == "millfail": print("java.lang.OutOfMemoryError: boom"); sys.exit(1)
    if hm == "hang": time.sleep(30)
    for i in range(7): print("+ h%d 1ms" % i)
    sys.exit(0)
if "signals.test.testOnly" in a and a[a.index("signals.test.testOnly") + 1].endswith("NoiseSpec") and "-k" not in a:
    fq = a[a.index("signals.test.testOnly") + 1]
    m = os.environ.get("FAKE_HIDDEN", "pass")
    if m == "millfail": print("java.lang.OutOfMemoryError: boom"); sys.exit(1)
    if m == "norun": print("No tests were executed"); sys.exit(0)
    if m == "nocompile": print("[error] Compilation failed"); sys.exit(1)
    if m == "hang": print("Running Test Class " + fq); print("+ a 1ms"); sys.stdout.flush(); time.sleep(30); sys.exit(0)
    print("Running Test Class com.other.OtherSuite"); print("- unrelated 1ms")
    print("Running Test Class " + fq)
    if m == "pass": print("+ a 1ms"); print("+ b 1ms"); sys.exit(0)
    if m == "fail": print("+ a 1ms"); print("- b 1ms"); print("*****FAILURES*****"); print("- b 1ms"); sys.exit(1)
    if m == "class": print("+ a 1ms"); print("- Unexpected failure 0ms"); sys.exit(1)
if "-k" in a:
    rm = os.environ.get("FAKE_REG_MODE")
    if rm == "silent": print("weird crash"); sys.exit(1)
    if rm == "notests": sys.exit(0)
    if rm == "hang": time.sleep(30)
    mods = []; cur = []
    for x in a[a.index("-k"):]:
        if x == "+": mods.append(cur); cur = []
        elif x.endswith(".test") or ".testOnly" in x or cur: cur.append(x)
    if cur: mods.append(cur)
    failing = os.environ.get("FAKE_FAIL_MODS" if tree else "FAKE_HEAD_FAIL_MODS", "").split(",")
    nf = 0
    for c in mods:
        mod = c[0].replace(".testOnly", "")
        print("Running Test Class pk." + mod.replace(".", "_") + "Spec"); print("+ ok 1ms")
        if mod in failing: print("[3] [error] %s.testForked 1 tests failed:" % mod); nf += 1
    if rm == "oom": print("[error] java.lang.OutOfMemoryError: Java heap space"); nf = max(nf, 1)
    if rm == "compile": print("[error] core.compile boom"); nf = max(nf, 1)
    if rm == "compile-nomodule": print("[error] backpressure.compile task failed"); nf = max(nf, 1)
    if rm == "build": print("[error] build.mill:3:1: boom"); nf = max(nf, 1)
    if nf: print("9/9, %d FAILED] mill 3s" % nf); sys.exit(1)
sys.exit(0)
"""

SPEC = 'package com.github.mercurievv.skreeep2\n\nobject NoiseSpec extends SimpleIOSuite { "secret-name" }\n'
FQ = "com.github.mercurievv.skreeep2.NoiseSpec"

class FakeBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        t = pathlib.Path(self.tmp)
        self.root = t / "ga"; self.rd = self.root / "runs" / "noise-g-1"
        (self.rd / "repo" / "out").mkdir(parents=True)
        (self.rd / "repo" / "out" / "junk").write_text("x")
        (self.rd / "repo" / "out-score").mkdir()
        (self.rd / "repo" / "a.txt").write_text("a")
        spec = "signals/test/src/com/github/mercurievv/skreeep2/NoiseSpec.scala"
        h = self.root / "base" / "noise" / "hidden" / spec
        h.parent.mkdir(parents=True); h.write_text(SPEC)
        (self.root / "head").mkdir()
        (self.root / "head-baseline.json").write_text(json.dumps({"modules": {"signals.test": True, "control.test": True}, "passes": {"signals.test": 1, "control.test": 1}}))
        fm = t / "fakemill"; fm.write_text(FAKE_MILL); fm.chmod(0o755)
        self.log = t / "fake.log"
        ho = t / "holdout"; ho.mkdir(); (ho / "f").write_text("x")
        g = ["git", "-C", str(ho), "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(g + ["init", "-q"], check=True); subprocess.run(g + ["add", "-A"], check=True)
        subprocess.run(g + ["commit", "-qm", "h"], check=True)
        (self.rd / "run.json").write_text(json.dumps(dict(run_id="noise-g-1", task="noise", arm="g", rep=1,
            start_epoch=100, end_epoch=160, exit_code=0, timed_out=False)))
        (self.rd / "transcript.jsonl").write_text((FX / "real-init-isolated.jsonl").read_text() + (FX / "clean.jsonl").read_text())
        (self.rd / "final.diff").write_text("")
        self.env = dict(GA_ROOT=str(self.root), GA_MILL=str(fm), GA_HOLDOUT_SRC=str(ho), GA_HOLDOUT_COMMIT="HEAD",
                        FAKE_HIDDEN="pass", GA_TEST_CAP="600", GA_REGRESS_CAP="1200", FAKE_LOG=str(self.log))
        self.saved = dict(os.environ)
        os.environ.update(self.env)
    def tearDown(self):
        os.environ.clear(); os.environ.update(self.saved)
        shutil.rmtree(self.tmp, ignore_errors=True)
    def calls(self):
        return [json.loads(l) for l in self.log.read_text().splitlines()] if self.log.exists() else []
    def run_score(self, **env):
        os.environ.update(env)
        score.main(str(self.rd))
        return json.loads((self.rd / "score.json").read_text())

class MainWithFakeMill(FakeBase):
    def test_solved_and_hidden_runs_only_its_suite(self):
        s = self.run_score()
        self.assertTrue(s["solved"], s); self.assertEqual(s["hidden_pass_ratio"], 1.0)
        self.assertEqual((s["turns"], s["wall_seconds"], s["regressions"]), (2, 60, []))
        self.assertTrue(s["holdout_passed"]); self.assertFalse(s["false_done"]); self.assertIsNone(s["error"])
        self.assertEqual(s["first_clean_compile_turn"], 1)
        st = self.rd / "score-tree"
        self.assertFalse((st / "out").exists()); self.assertFalse((st / "out-score").exists())
        self.assertTrue((st / "a.txt").exists())
        argl = [c["args"] for c in self.calls()]
        self.assertIn(["signals.test.testOnly", FQ], [a[-2:] for a in argl])
        reg = [a for a in argl if "-k" in a]
        self.assertEqual(len(reg), 1)
        self.assertIn("control.test", reg[0]); self.assertNotIn("holdout.test", reg[0])
        self.assertNotIn("backend.opencl.test", reg[0]); self.assertFalse(any(x.startswith("signals.test") for x in reg[0]))
        self.assertEqual(reg[0][reg[0].index("-k") - 2:reg[0].index("-k") + 1], ["-j", "1", "-k"])
    def test_other_suites_of_task_module_scored_as_regressions(self):
        p = self.rd / "repo" / "signals" / "test" / "src"; p.mkdir(parents=True)
        (p / "Other.scala").write_text("package pk\nobject OtherSpec extends SimpleIOSuite\n")
        s = self.run_score(FAKE_FAIL_MODS="signals.test")
        reg = [c["args"] for c in self.calls() if "-k" in c["args"]][0]
        i = reg.index("signals.test.testOnly"); self.assertEqual(reg[i + 1], "pk.OtherSpec")
        self.assertEqual(s["regressions"], ["signals.test"]); self.assertFalse(s["solved"])
        self.assertEqual(s["hidden_pass_ratio"], 1.0)
    def test_leaked_agent_environment_is_an_error(self):
        (self.rd / "transcript.jsonl").write_text((FX / "real-init-leaked-g.jsonl").read_text() + (FX / "clean.jsonl").read_text())
        s = self.run_score()
        self.assertTrue(s["error"].startswith("agent environment leaked: mcp_servers="), s["error"])  # error -> excluded from headline
    def test_ungated_hook_event_is_an_error(self):
        run = json.loads((self.rd / "run.json").read_text()); run["arm"] = "u"
        (self.rd / "run.json").write_text(json.dumps(run))
        hook = json.dumps({"type": "system", "subtype": "hook_started", "hook_name": "Stop", "hook_event": "Stop"})
        (self.rd / "transcript.jsonl").write_text((FX / "real-init-isolated.jsonl").read_text() + hook + "\n" + (FX / "clean.jsonl").read_text())
        s = self.run_score()
        self.assertEqual(s["error"], "agent environment leaked: hooks=Stop")
    def test_regression_attributed_per_module(self):
        s = self.run_score(FAKE_FAIL_MODS="control.test")
        self.assertEqual(s["regressions"], ["control.test"]); self.assertFalse(s["solved"])
    def test_module_failing_at_head_is_not_a_regression(self):
        (self.root / "head-baseline.json").write_text(json.dumps({"modules": {"signals.test": True, "control.test": False}, "passes": {"signals.test": 1, "control.test": 1}}))
        s = self.run_score(FAKE_FAIL_MODS="control.test")
        self.assertEqual(s["regressions"], []); self.assertTrue(s["solved"])
    def test_unattributed_regression_failure(self):
        s = self.run_score(FAKE_REG_MODE="silent")
        self.assertFalse(s["solved"]); self.assertTrue(s["regressions"]); self.assertIn("regression", s["error"])
    def test_other_error_line_is_mill_failure(self):
        s = self.run_score(FAKE_REG_MODE="oom")
        self.assertFalse(s["solved"]); self.assertTrue(s["error"].startswith("mill failed (regressions):"), s["error"])
        self.assertIn("OutOfMemoryError", s["error"])
    def test_agent_broke_a_module_without_tests_is_a_regression_not_an_error(self):
        s = self.run_score(FAKE_REG_MODE="compile-nomodule")
        self.assertFalse(s["solved"]); self.assertIsNone(s["error"]); self.assertEqual(s["regressions"], ["<compile:backpressure>"])
    def test_agent_broke_the_build_file(self):
        s = self.run_score(FAKE_REG_MODE="build")
        self.assertFalse(s["solved"]); self.assertIsNone(s["error"]); self.assertEqual(s["regressions"], ["<build>"])
    def test_agent_broke_the_build_file_real_mill_shape(self):
        s = self.run_score(FAKE_BUILD_BROKEN=str(HERE / "fixtures" / "mill" / "build-broken-resolve.txt"))
        self.assertFalse(s["solved"]); self.assertIsNone(s["error"], s); self.assertEqual(s["regressions"], ["<build>"])
        self.assertFalse(s["hidden_compiled"]); self.assertFalse(s["holdout_passed"])
        self.assertFalse([c for c in self.calls() if "-k" in c["args"]])  # nothing left to run once resolve shows the build is broken
    def test_module_listing_failure_is_recorded(self):
        s = self.run_score(FAKE_FAIL_MODS="control.test", FAKE_ALL_RESOLVE_FAIL="1")
        self.assertFalse(s["solved"]); self.assertEqual(s["regressions"], ["control.test"])
        self.assertIn("resolve __:Module failed", s["error"])
    def test_module_listing_only_when_attribution_needed(self):
        s = self.run_score(FAKE_ALL_RESOLVE_FAIL="1")
        self.assertTrue(s["solved"], s); self.assertIsNone(s["error"])
    def test_old_format_baseline_is_an_error(self):
        (self.root / "head-baseline.json").write_text(json.dumps({"modules": {"signals.test": True, "control.test": True}}))
        s = self.run_score()
        self.assertFalse(s["solved"]); self.assertIn("baseline outdated", s["error"])
    def test_regression_timeout_is_an_outcome_not_an_error(self):
        s = self.run_score(FAKE_REG_MODE="hang", GA_REGRESS_CAP="1")
        self.assertFalse(s["solved"]); self.assertIn("regressions", s["score_timeouts"])
        self.assertEqual(s["regressions"], ["<timeout>"]); self.assertIsNone(s["error"])
    def test_regression_run_that_ran_no_tests(self):
        s = self.run_score(FAKE_REG_MODE="notests")
        self.assertFalse(s["solved"]); self.assertEqual(s["regressions"], ["<tests did not run>"]); self.assertIsNone(s["error"])
    def test_bench_test_excluded_from_regressions(self):
        s = self.run_score(FAKE_FAIL_MODS="bench.test")
        reg = [c["args"] for c in self.calls() if "-k" in c["args"]][0]
        self.assertNotIn("bench.test", reg); self.assertEqual(s["regressions"], []); self.assertTrue(s["solved"], s)
    def test_holdout_mill_failure_is_an_error(self):
        s = self.run_score(FAKE_HOLDOUT="millfail")
        self.assertFalse(s["solved"]); self.assertTrue(s["error"].startswith("mill failed (holdout):"), s["error"])
    def test_holdout_timeout_is_unsolved_not_error(self):
        s = self.run_score(FAKE_HOLDOUT="hang", GA_TEST_CAP="1", FAKE_HIDDEN="pass")
        self.assertFalse(s["solved"]); self.assertFalse(s["holdout_passed"]); self.assertIn("holdout.test", s["score_timeouts"])
        self.assertIsNone(s["error"])
    def test_failed_test_ratio_and_false_done(self):
        s = self.run_score(FAKE_HIDDEN="fail")
        self.assertFalse(s["solved"]); self.assertEqual(s["hidden_pass_ratio"], 0.5); self.assertTrue(s["false_done"])
    def test_class_level_failure_is_not_solved(self):
        s = self.run_score(FAKE_HIDDEN="class")
        self.assertFalse(s["solved"]); self.assertLess(s["hidden_pass_ratio"], 1.0)
    def test_no_compile(self):
        s = self.run_score(FAKE_HIDDEN="nocompile")
        self.assertFalse(s["hidden_compiled"]); self.assertEqual(s["hidden_pass_ratio"], 0.0); self.assertFalse(s["solved"])
    def test_hidden_suite_did_not_run(self):
        s = self.run_score(FAKE_HIDDEN="norun")
        self.assertFalse(s["solved"]); self.assertTrue(s["hidden_compiled"]); self.assertIn("hidden suite did not run", s["error"])
    def test_mill_infrastructure_failure(self):
        s = self.run_score(FAKE_HIDDEN="millfail")
        self.assertFalse(s["solved"]); self.assertTrue(s["error"].startswith("mill failed:")); self.assertIn("OutOfMemoryError", s["error"])
    def test_hang_counts_as_fail(self):
        s = self.run_score(FAKE_HIDDEN="hang", GA_TEST_CAP="1")
        self.assertFalse(s["solved"]); self.assertIn("signals.test", s["score_timeouts"])
    def test_no_baseline(self):
        (self.root / "head-baseline.json").unlink()
        s = self.run_score()
        self.assertFalse(s["solved"]); self.assertIn("no baseline", s["error"])
    def test_empty_module_list(self):
        s = self.run_score(FAKE_MODULES="holdout.test")
        self.assertFalse(s["solved"]); self.assertIn("no test modules", s["error"])
    def test_agent_timeout_not_solved_not_false_done(self):
        run = json.loads((self.rd / "run.json").read_text()); run.update(timed_out=True, exit_code=124)
        (self.rd / "run.json").write_text(json.dumps(run))
        s = self.run_score()
        self.assertFalse(s["solved"]); self.assertFalse(s["false_done"]); self.assertTrue(s["timed_out"])
    def test_agent_timeout_with_empty_transcript_has_no_error(self):
        run = json.loads((self.rd / "run.json").read_text()); run.update(timed_out=True, exit_code=124)
        (self.rd / "run.json").write_text(json.dumps(run)); (self.rd / "transcript.jsonl").write_text("")
        s = self.run_score()
        self.assertFalse(s["solved"]); self.assertIsNone(s["error"]); self.assertIsNone(s["turns"])
    def test_empty_transcript(self):
        (self.rd / "transcript.jsonl").write_text("")
        s = self.run_score()
        self.assertEqual(s["error"], "no result event"); self.assertIsNone(s["turns"])
    def test_exception_writes_record(self):
        (self.rd / "run.json").unlink()
        s = self.run_score()
        self.assertFalse(s["solved"]); self.assertIn("FileNotFoundError", s["error"])
    def test_empty_task_env_values_rejected(self):
        orig = score.read_task_env
        score.read_task_env = lambda p: ("", "", "", "")
        try:
            s = self.run_score()
        finally:
            score.read_task_env = orig
        self.assertFalse(s["solved"]); self.assertIn("task.env", s["error"])
    def test_partial_record_says_incomplete(self):
        seen = []
        orig = score.run_mill
        def spy(*a, **k):
            seen.append(json.loads((self.rd / "score.json").read_text())["error"])
            return orig(*a, **k)
        score.run_mill = spy
        try:
            s = self.run_score()
        finally:
            score.run_mill = orig
        self.assertEqual(seen[0], "scoring incomplete"); self.assertIsNone(s["error"])
    def test_keyboard_interrupt_recorded_and_reraised(self):
        orig = score.run_mill
        def boom(*a, **k): raise KeyboardInterrupt()
        score.run_mill = boom
        try:
            with self.assertRaises(KeyboardInterrupt):
                score.main(str(self.rd))
        finally:
            score.run_mill = orig
        s = json.loads((self.rd / "score.json").read_text())
        self.assertFalse(s["solved"]); self.assertIn("KeyboardInterrupt", s["error"])
    def test_task_env_sourced_in_sh(self):
        self.assertEqual(score.read_task_env(HERE.parent / "tasks" / "noise" / "task.env")[0], "signals.test")
    def test_export_holdout_failure_raises(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(Exception):
                score._export_holdout(self.tmp + "/nonexistent", "HEAD", d)

class BaselineMode(FakeBase):
    def setUp(self):
        super().setUp()
        (self.root / "head-baseline.json").unlink()
    def test_writes_baseline(self):
        score.baseline(str(self.root))
        b = json.loads((self.root / "head-baseline.json").read_text())
        self.assertEqual(b["modules"], {"signals.test": True, "control.test": True})
        self.assertNotIn("bench.test", b["modules"])
        reg = [c for c in self.calls() if "-k" in c["args"]][0]
        self.assertTrue(reg["cwd"].endswith("/head")); self.assertEqual(reg["out"], "out")
    def test_failing_module_recorded(self):
        os.environ["FAKE_HEAD_FAIL_MODS"] = "control.test"
        score.baseline(str(self.root))
        b = json.loads((self.root / "head-baseline.json").read_text())
        self.assertEqual(b["modules"], {"signals.test": True, "control.test": False})
    def test_per_module_pass_counts(self):
        for m in ("signals.test", "control.test"):
            d = self.root / "head" / m.replace(".", "/") / "src"; d.mkdir(parents=True)
            (d / "S.scala").write_text("package pk\nobject %sSpec extends SimpleIOSuite\n" % m.replace(".", "_"))
        score.baseline(str(self.root))
        b = json.loads((self.root / "head-baseline.json").read_text())
        self.assertEqual(b["passes"], {"signals.test": 1, "control.test": 1})
    def test_oom_is_loud(self):
        os.environ["FAKE_REG_MODE"] = "oom"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
        self.assertFalse((self.root / "head-baseline.json").exists())
    def test_compile_failure_at_head_is_loud(self):
        os.environ["FAKE_REG_MODE"] = "compile"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
    def test_no_tests_at_head_is_loud(self):
        os.environ["FAKE_REG_MODE"] = "notests"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
    def test_resolve_failure_is_loud(self):
        os.environ["FAKE_RESOLVE_FAIL"] = "1"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
        self.assertFalse((self.root / "head-baseline.json").exists())
    def test_empty_list_is_loud(self):
        os.environ["FAKE_MODULES"] = "holdout.test"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
    def test_non_test_failure_is_loud(self):
        os.environ["FAKE_REG_MODE"] = "silent"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
        self.assertFalse((self.root / "head-baseline.json").exists())
    def test_timeout_is_loud(self):
        os.environ["FAKE_REG_MODE"] = "hang"; os.environ["GA_REGRESS_CAP"] = "1"
        with self.assertRaises(score.ScoreError): score.baseline(str(self.root))
    def test_cli_exit_code(self):
        os.environ["FAKE_RESOLVE_FAIL"] = "1"
        r = subprocess.run([sys.executable, str(HERE.parent / "score.py"), "--baseline"], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0); self.assertTrue(r.stderr.strip())

if __name__ == "__main__":
    unittest.main()
