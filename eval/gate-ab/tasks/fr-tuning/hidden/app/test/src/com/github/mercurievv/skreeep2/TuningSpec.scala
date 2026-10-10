package com.github.mercurievv.skreeep2

import weaver.*
import spire.implicits.*

import com.github.mercurievv.skreeep2.score.Notes

/** Authored for the gate feature-request study (spec 2026-10-10); each test names the request sentence it checks. */
object TuningSpec extends SimpleIOSuite:

  private def near(a: Double, b: Double) = math.abs(a - b) < 1e-9

  // "Notes[Double](440.0) is today's tuning" — A, three octaves below A4, is 55 Hz
  pureTest("a 440 reference is today's tuning") {
    expect(near(Notes[Double](440.0).A, 55.0))
  }

  // "Notes[Double](432.0) tunes everything to A4 = 432 Hz" + "pitch ... scales with the reference"
  pureTest("a 432 reference scales pitch") {
    val n = Notes[Double](432.0)
    expect(near(n.A, 54.0)) and expect(near(n.pitch(12), 108.0))
  }

  // "justPitch ... scales with the reference": the just fifth is 3/2 of A
  pureTest("justPitch scales with the reference") {
    expect(near(Notes[Double](432.0).justPitch(7), 81.0))
  }

  // "the note names ... scale with the reference"
  pureTest("note names scale with the reference") {
    expect(near(Notes[Double](432.0).C / Notes[Double](440.0).C, 432.0 / 440.0))
  }
