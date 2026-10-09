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
    def d(self, gs, us, gf=0, uf=0, gw=100, uw=100, gn=24, un=24):
        return report.decide({"solve_rate": gs, "false_done": gf, "median_wall": gw, "n": gn},
                             {"solve_rate": us, "false_done": uf, "median_wall": uw, "n": un})
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
    def test_false_done_needs_three_ungated(self):  # Ruling 21: 1 vs 0 or 2 vs 1 is noise, not "halved"
        self.assertEqual(self.d(0.6, 0.6, gf=0, uf=1), "inconclusive")
        self.assertEqual(self.d(0.6, 0.6, gf=1, uf=2), "inconclusive")
        self.assertEqual(self.d(0.6, 0.6, gf=1, uf=3), "pays off")
    def test_false_done_compared_as_rates(self):  # Ruling 21: unequal n (excluded runs) must not fake a halving
        self.assertEqual(self.d(0.6, 0.6, gf=2, uf=4, gn=12, un=24), "inconclusive")   # 0.167 vs 0.167
        self.assertEqual(self.d(0.6, 0.6, gf=2, uf=4, gn=24, un=12), "pays off")       # 0.083 <= 0.333/2
        self.assertEqual(self.d(0.6, 0.6, gf=2, uf=3, gn=24, un=24), "inconclusive")   # 0.083 > 0.0625
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
            self.assertNotIn("raw counts", s)
            self.assertIn("| false_done (rate) | 0 (0.00) | 0 (0.00) |", s)
            self.assertIn("u.false_done >= 3", s)
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


if __name__ == "__main__":
    unittest.main()
