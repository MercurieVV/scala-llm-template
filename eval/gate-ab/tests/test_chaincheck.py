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
        self.assertIsNone(out["chain_regressions"])   # final review I3: a partial check is not 0 regressions

    def test_erosion_failure_keeps_the_regression_count(self):
        env = {"GA_ROOT": self.root, "GA_HOME": self.home, "GA_MILL": "./mill"}
        with mock.patch.dict(os.environ, env), \
             mock.patch.object(chaincheck.erosion, "measure", side_effect=chaincheck.erosion.ErosionError("parse")):
            out = chaincheck.main(self.rd, self.earlier)
        self.assertIsNone(out["error"])
        self.assertEqual(out["chain_regressions"], 1)
        self.assertIsNone(out["erosion"])
        self.assertIn("parse", out["erosion_error"])
