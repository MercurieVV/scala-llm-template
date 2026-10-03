import csv, json, os, sys, tempfile, unittest, pathlib
sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
import report

class Stats(unittest.TestCase):
    def test_wilson_known_value(self):
        lo, hi = report.wilson(12, 24)
        self.assertAlmostEqual(lo, 0.314, places=3); self.assertAlmostEqual(hi, 0.686, places=3)
    def test_wilson_zero_n(self):
        self.assertEqual(report.wilson(0, 0), (0.0, 1.0))
    def test_sign_test(self):
        self.assertAlmostEqual(report.sign_test([1, 1, 1, 1, 1, 1, 1, 1]), 2 / 256)
        self.assertAlmostEqual(report.sign_test([1, -1, 0]), 1.0)

class Decide(unittest.TestCase):
    def d(self, gs, us, gf=0, uf=0, gw=100, uw=100):
        return report.decide({"solve_rate": gs, "false_done": gf, "median_wall": gw}, {"solve_rate": us, "false_done": uf, "median_wall": uw})
    def test_pays_off_on_solve_rate(self): self.assertEqual(self.d(0.8, 0.5), "pays off")
    def test_pays_off_on_false_done(self): self.assertEqual(self.d(0.6, 0.6, gf=2, uf=6), "pays off")
    def test_too_slow(self): self.assertEqual(self.d(0.8, 0.5, gw=300, uw=100), "does not pay off")
    def test_inconclusive(self): self.assertEqual(self.d(0.6, 0.5), "inconclusive")
    def test_missing_wall_blocks_pays_off(self):
        for gw, uw in ((None, 100), (100, None), (None, None)):
            self.assertEqual(self.d(0.8, 0.5, gw=gw, uw=uw), "inconclusive")
    def test_exact_gain_boundary(self):
        self.assertEqual(report.decide({"solve_rate": 12 / 20, "false_done": 0, "median_wall": 100}, {"solve_rate": 8 / 20, "false_done": 0, "median_wall": 100}), "pays off")
        self.assertEqual(self.d(0.6, 0.4), "pays off")
    def test_exact_quarter_not_inconclusive(self):
        self.assertEqual(self.d(0.25, 0.5), "does not pay off")
        self.assertEqual(self.d(0.75, 0.5), "pays off")
        self.assertEqual(self.d(0.4, 0.65), "does not pay off")
    def test_no_false_done_win_when_ungated_zero(self):
        self.assertEqual(self.d(0.6, 0.6, gf=0, uf=0), "inconclusive")
    def test_worse(self): self.assertEqual(self.d(0.2, 0.6), "does not pay off")

def rec(rid, task, arm, rep, **kw):
    r = dict(run_id=rid, task=task, arm=arm, rep=rep, solved=False, regressions=[], test_tampering=[],
             hardcoding_suspects=[], build_edits=[], false_done=False, timed_out=False, contaminated=False,
             contamination=[], gate_blocks={}, wall_seconds=100, turns=10, cost_usd=1.0, score_timeouts=[], error=None)
    r.update(kw)
    return r

class EndToEnd(unittest.TestCase):
    def test_counts(self):
        runs = [
            rec("a-g-1", "a", "g", 1, solved=True, gate_blocks={"turn-end": 2}, build_edits=["build.mill"]),
            rec("a-u-1", "a", "u", 1, turns=None, cost_usd=None, regressions=["<compile:core>"]),
            rec("a-g-9", "a", "g", 9, solved=True),                                   # smoke
            rec("a-u-2", "a", "u", 2, error="scoring incomplete"),                    # error
            rec("a-g-2", "a", "g", 2, solved=True, contaminated=True, contamination=["read holdout"]),
            rec("a-u-3", "a", "u", 3, timed_out=True, regressions=["<timeout>"]),    # timeout counts
        ]
        with tempfile.TemporaryDirectory() as d:
            for r in runs:
                os.makedirs(os.path.join(d, r["run_id"]))
                with open(os.path.join(d, r["run_id"], "score.json"), "w") as f:
                    json.dump(r, f)
            report.main(d)
            with open(os.path.join(d, "results.csv")) as f: rows = list(csv.DictReader(f))
            self.assertEqual(len(rows), 5)
            self.assertNotIn("a-g-9", [r["run_id"] for r in rows])
            by = {r["run_id"]: r for r in rows}
            self.assertEqual(by["a-g-1"]["gate_blocks_total"], "2")
            self.assertEqual(by["a-g-1"]["build_edits"], "build.mill")
            self.assertEqual(by["a-g-1"]["build_edits_count"], "1")
            self.assertEqual(by["a-u-2"]["counted"], "no")
            self.assertEqual(by["a-u-3"]["counted"], "yes")
            with open(os.path.join(d, "summary.md")) as f: s = f.read()
            self.assertIn("\nVerdict: pays off\n", s)
            self.assertIn("a-g-9", s)
            self.assertIn("false_done compared as raw counts; arms have n_g=1 n_u=2", s)
            self.assertIn("1 smoke runs", s)
            self.assertIn("| n (headline) | 1 | 2 |", s)
            self.assertIn("| timeouts (counted, unsolved) | 0 | 1 |", s)
            self.assertIn("| contaminated (excluded) | 1 | 0 |", s)
            self.assertIn("| error (excluded) | 0 | 1 |", s)
            self.assertIn("- a-u-2 (error: scoring incomplete)", s)
            self.assertIn("- a-g-2 (contaminated: read holdout)", s)
            self.assertIn("| <timeout> | 0 | 1 |", s)
            self.assertIn("| turn-end | 2 | 1 |", s)
            self.assertIn("| median turns (n) | 10.0 (1) | 10.0 (1) |", s)

if __name__ == "__main__":
    unittest.main()
