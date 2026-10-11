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
        self.assertEqual(ms["small"]["sloc"], 6)   # scalafmt puts the match on its own line
        self.assertEqual(ms["big"]["cc"], 12)     # 1 + 11 ifs
        self.assertEqual(ms["outer"]["cc"], 1)    # inner's if is inner's
        self.assertEqual(ms["outer"]["sloc"], 3)  # the comment line does not count
        self.assertEqual(ms["inner"]["cc"], 2)
