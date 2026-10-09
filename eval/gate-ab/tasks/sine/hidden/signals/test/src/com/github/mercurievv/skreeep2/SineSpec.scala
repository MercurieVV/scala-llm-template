package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.signals.Sine
import io.github.mercurievv.spireopencl.algebra.Modulo
import spire.std.double.given

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): what Sine.sineCalc's and Sine.advance's scaladoc states, at scalar Double. */
object SineSpec extends SimpleIOSuite:

  private given Modulo[Double] = Modulo.given_Modulo_Double
  private val twoPi = 2 * math.Pi
  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-9

  // "`sin(phi + 2*pi*f*(t - chunkStart))`" — chunkTime2Pi is 2*pi*(t - chunkStart); "One partial … how loud"
  pureTest("a sample is sin(phase + chunkTime2Pi * frequency), scaled by the partial's volume") {
    val got = Sine.sineCalc(Sine(multiple = 2.0, volume = 0.3), 440.0, 0.7, twoPi * 0.001)
    expect(near(got, math.sin(0.7 + twoPi * 0.001 * 440.0) * 0.3))
  }

  // "given the phase it starts this chunk at"
  pureTest("at the chunk start the sample is sin(phase) times volume") {
    expect(near(Sine.sineCalc(Sine(1.0, 0.5), 1000.0, 1.2, 0.0), math.sin(1.2) * 0.5))
  }

  // "The phase one chunk later"
  pureTest("advance adds one chunk's worth of phase") {
    expect(near(Sine.advance(10.0, twoPi, 0.01, 0.5), 0.5 + twoPi * 10.0 * 0.01))
  }

  // "folded back into a single turn"
  pureTest("advance wraps the phase into one turn") {
    val p = Sine.advance(440.0, twoPi, 0.1, 1.0)
    expect(p >= 0.0) and expect(p < twoPi) and expect(math.abs(math.sin(p) - math.sin(1.0 + twoPi * 440.0 * 0.1)) < 1e-6)
  }

  // "The advance is constant across the chunk": the next chunk starts where this one ends
  pureTest("the advanced phase continues the waveform across a chunk boundary") {
    val s = Sine(1.0, 1.0); val f = 523.25; val dur = 512.0 / 48000
    val endOfThis = Sine.sineCalc(s, f, 0.3, twoPi * dur)
    val startOfNext = Sine.sineCalc(s, f, Sine.advance(f, twoPi, dur, 0.3), 0.0)
    expect(math.abs(endOfThis - startOfNext) < 1e-9)
  }
