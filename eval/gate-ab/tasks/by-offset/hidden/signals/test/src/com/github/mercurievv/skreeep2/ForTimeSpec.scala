package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.audio.{AudioConfig, SampleRate}

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): ForTime.byOffset — one chunk's sample times in seconds, from sample `offset`. `ForTime` has no
  * scaladoc; these tests check only `.time`, the field every caller (`GloabalSignals.create`, the holdout's `OfflineRender`) reads.
  */
object ForTimeSpec extends SimpleIOSuite:

  private given Conversion[Seq[Double], Seq[Double]] = identity(_)
  private val ac = AudioConfig.default.copy(SAMPLE_RATE = SampleRate(48000))
  private def near(a: Double, b: Double): Boolean = math.abs(a - b) < 1e-12

  pureTest("one chunk: clipSize sample times, the first at offset / sample rate") {
    val t = ForTime.byOffset[Seq[Double]](48000L, ac).time
    expect(t.size == ac.clipSize) and expect(near(t.head, 1.0))
  }

  pureTest("consecutive samples are one sample period apart") {
    val t = ForTime.byOffset[Seq[Double]](1000L, ac).time
    expect(t.zip(t.tail).forall((a, b) => near(b - a, 1.0 / 48000)))
  }

  pureTest("consecutive chunks tile the timeline without gap or overlap") {
    val a = ForTime.byOffset[Seq[Double]](0L, ac).time
    val b = ForTime.byOffset[Seq[Double]](ac.clipSize.toLong, ac).time
    expect(near(b.head, a.last + 1.0 / 48000))
  }
