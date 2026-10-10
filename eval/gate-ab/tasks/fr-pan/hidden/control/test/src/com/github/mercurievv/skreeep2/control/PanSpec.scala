package com.github.mercurievv.skreeep2.control

import weaver.*

/** Authored for the gate feature-request study (spec 2026-10-10); each test names the request sentence it checks. */
object PanSpec extends SimpleIOSuite:

  private val mode = new MixerMode(Vector("kick", "snare"), 2)

  private def pans(cs: List[Command]): List[(String, Double)] = cs.collect { case Command.SetPan(i, p) => (i, p) }

  // "each detent moves the pan by 0.05, pan starts at 0.0" + "emits ... SetPan"
  pureTest("a V-Pot turn pans its strip's instrument by 0.05 per detent") {
    val (_, cs, _) = mode.step(mode.initial, Control.Encoder(0, 3))
    val ps = pans(cs)
    expect(ps.size == 1) and expect(cs.size == 1) and expect(ps.headOption.exists((i, p) => i == "kick" && math.abs(p - 0.15) < 1e-9))
  }

  // "Turning a strip's V-Pot ... pans that strip's instrument"
  pureTest("turning left pans left") {
    val ps = pans(mode.step(mode.initial, Control.Encoder(1, -4))._2)
    expect(ps.headOption.exists((i, p) => i == "snare" && math.abs(p + 0.2) < 1e-9))
  }

  // "clamped to -1.0 .. 1.0" + "only when the pan actually changed"
  pureTest("pan is clamped to -1 .. 1 and a turn that changes nothing emits nothing") {
    val (s1, c1, _) = mode.step(mode.initial, Control.Encoder(0, 40))
    val (_, c2, _) = mode.step(s1, Control.Encoder(0, 5))
    expect(pans(c1).headOption.exists((_, p) => math.abs(p - 1.0) < 1e-9)) and expect(c2.isEmpty)
  }

  // "turning a V-Pot never changes a level"
  pureTest("pan and level stay separate") {
    val (s1, _, _) = mode.step(mode.initial, Control.Encoder(0, 2))
    val (_, cs, _) = mode.step(s1, Control.Fader(0, 0.5))
    expect(cs == List(Command.SetLevel("kick", 0.5)))
  }

  // "each detent moves the pan" — moves accumulate
  pureTest("turns accumulate") {
    val (s1, _, _) = mode.step(mode.initial, Control.Encoder(0, 2))
    val ps = pans(mode.step(s1, Control.Encoder(0, -6))._2)
    expect(ps.headOption.exists((_, p) => math.abs(p + 0.2) < 1e-9))
  }
