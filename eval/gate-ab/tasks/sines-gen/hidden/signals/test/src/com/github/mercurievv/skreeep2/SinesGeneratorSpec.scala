package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.SinesGenerator
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what SinesGenerator's scaladoc states, at Double. */
object SinesGeneratorSpec extends SimpleIOSuite:

  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-12

  // "`cnt` partials at 2f, 4f, 6f… of the fundamental, each with amplitude `vol / multiple`, paired with the id of the cell"; "Ids are positional"
  pureTest("createSines: cnt partials at even multiples, amplitude vol / multiple, positional ids") {
    val s = SinesGenerator.createSines[Double](1.2, 3, 10)
    expect(s.map(_._1) == List(10, 11, 12)) and
      expect(s.map(_._2.multiple) == List(2.0, 4.0, 6.0)) and
      expect(s.map(_._2.volume).zip(List(0.6, 0.3, 0.2)).forall(near))
  }

  // "**`cnt` is the number of partials.**"; "`cnt = 2` used to give zero partials"
  pureTest("createSines with cnt = 2 gives two partials, not zero") {
    expect(SinesGenerator.createSines[Double](1.0, 2, 0).size == 2)
  }

  // "each partial's multiple of the fundamental and its own amplitude, in the caller's order"; ids: "Ids are positional" (createSines' doc, same object)
  pureTest("fromRatios keeps the caller's ratios, amplitudes and order, ids from idBase") {
    val s = SinesGenerator.fromRatios(List((1.0, 0.5), (2.76, 0.25), (5.4, 0.1)), 7)
    expect(s.map(_._1) == List(7, 8, 9)) and
      expect(s.map(_._2.multiple) == List(1.0, 2.76, 5.4)) and
      expect(s.map(_._2.volume) == List(0.5, 0.25, 0.1))
  }

  // "clustered around the fundamental (`multiple = 1`), spread symmetrically by `spread` per step and each carrying `vol / cnt`"
  pureTest("detuned: symmetric cluster around 1 with step spread, each vol / cnt") {
    val s = SinesGenerator.detuned[Double](0.9, 3, 0.01, 0)
    // the scaladoc does not state an order, so compare as a set
    expect(s.map(_._2.multiple).sorted.zip(List(0.99, 1.0, 1.01)).forall(near)) and expect(s.map(_._2.volume).forall(v => near(v, 0.3)))
  }

  pureTest("detuned with an even count has no partial exactly at 1 and stays symmetric") {
    val m = SinesGenerator.detuned[Double](1.0, 4, 0.02, 0).map(_._2.multiple)
    expect(!m.exists(near(_, 1.0))) and expect(near(m.sum / m.size, 1.0))
  }
