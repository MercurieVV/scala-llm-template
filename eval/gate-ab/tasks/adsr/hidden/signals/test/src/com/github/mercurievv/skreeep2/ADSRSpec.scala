package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.envelopes.ADSR
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what ADSR's scaladoc states, at scalar Double (masks from `OrderS.orderedField`). Every point lies
  * strictly inside a segment: values on a boundary depend on the masks' strictness, which the scaladoc does not state.
  */
object ADSRSpec extends SimpleIOSuite:

  // attack 0.1, decay 0.2, duration (the note's whole step) 1.0, release 0.4, sustain level 0.5; the note starts at 2.0
  private val env = ADSR[Double](attack = 0.1, decay = 0.2, duration = 1.0, release = 0.4, sustainLevel = 0.5)
  private def at(t: Double): Double = env.amplitudeAt(t, 2.0)
  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-9

  // "ramp 0→1 over `attack`"
  pureTest("attack ramps linearly from 0 towards 1") {
    expect(near(at(2.05), 0.5)) and expect(near(at(2.025), 0.25))
  }

  // "1→`sustainLevel` over `decay`"
  pureTest("decay falls linearly from 1 to the sustain level") {
    expect(near(at(2.2), 0.75)) and expect(near(at(2.15), 0.875))
  }

  // "flat over `sustain`"; "`duration` is the note's whole step (attack+decay+sustain)"
  pureTest("sustain holds the sustain level until the step ends") {
    expect(near(at(2.5), 0.5)) and expect(near(at(2.99), 0.5))
  }

  // "then `sustainLevel`→0 over `release`" — release starts where the step ends
  pureTest("release falls linearly from the sustain level to 0") {
    expect(near(at(3.2), 0.25)) and expect(near(at(3.1), 0.375))
  }

  // the shape is 0 outside attack..release ("ramp 0→1", "`sustainLevel`→0")
  pureTest("silent before the note starts and after the release ends") {
    expect(near(at(1.0), 0.0)) and expect(near(at(1.999), 0.0)) and expect(near(at(3.5), 0.0)) and expect(near(at(10.0), 0.0))
  }

  pureTest("the start time shifts the whole shape") {
    expect(near(env.amplitudeAt(7.05, 7.0), 0.5)) and expect(near(env.amplitudeAt(8.2, 7.0), 0.25))
  }
