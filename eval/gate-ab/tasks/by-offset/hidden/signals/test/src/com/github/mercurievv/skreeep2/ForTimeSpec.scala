package com.github.mercurievv.skreeep2

import com.github.mercurievv.skreeep2.audio.{AudioConfig, SampleRate}

import weaver.*

/** Hidden spec (gate evaluation, 2026-10-09): ForTime.byOffset — one chunk's sample numbers from `offset`, and their times in seconds. `ForTime` has
  * no scaladoc; these tests state what its callers (`GloabalSignals.create`, the holdout's `OfflineRender`) rely on.
  */
object ForTimeSpec extends SimpleIOSuite:

  private given Conversion[Seq[Double], Seq[Double]] = identity(_)
  private val ac = AudioConfig.default.copy(SAMPLE_RATE = SampleRate(48000))

  pureTest("one chunk: clipSize consecutive sample numbers starting at the offset") {
    val ft = ForTime.byOffset[Seq[Double]](1000L, ac)
    expect(ft.sampleNumber.size == ac.clipSize) and
      expect(ft.sampleNumber.head == 1000.0) and
      expect(ft.sampleNumber.zip(ft.sampleNumber.tail).forall((a, b) => b - a == 1.0))
  }

  pureTest("times are sample numbers divided by the sample rate") {
    val ft = ForTime.byOffset[Seq[Double]](48000L, ac)
    expect(ft.time.head == 1.0) and expect(ft.time.zip(ft.sampleNumber).forall((t, n) => math.abs(t - n / 48000.0) < 1e-12))
  }

  pureTest("consecutive chunks tile the timeline without gap or overlap") {
    val a = ForTime.byOffset[Seq[Double]](0L, ac)
    val b = ForTime.byOffset[Seq[Double]](ac.clipSize.toLong, ac)
    expect(b.sampleNumber.head == a.sampleNumber.last + 1.0)
  }
