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
        self.assertIsNone(cr.step_failures({"solved": True, "regression_count": 0}, {"chain_regressions": 0, "error": "boom"}))

    def test_gate_verdict_withheld_while_steps_are_unknown(self):
        self.assertEqual(cr.gate_line(3, 1, ["a-u-1"]), "Gate: incomplete — unscored steps a-u-1 (u - gs = 2 so far)")
        self.assertEqual(cr.gate_line(3, 1, []), "Gate: gate pays on chains (u - gs = 2)")

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
