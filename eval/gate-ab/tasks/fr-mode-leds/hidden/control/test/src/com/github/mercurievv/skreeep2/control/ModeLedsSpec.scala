package com.github.mercurievv.skreeep2.control

import weaver.*

/** Authored for the gate feature-request study (spec 2026-10-10); each test names the request sentence it checks. */
object ModeLedsSpec extends SimpleIOSuite:

  private val a = new MixerMode(Vector("kick"), 1)
  private val b = new MixerMode(Vector("pad"), 1)
  private val modes = Modes.switching(Vector(a, b))

  // "its enter output also contains Feedback.Led(Button.ModeKey(i), i == current)"
  pureTest("entering lights the current mode's key and darkens the others") {
    val fb = modes.enter(modes.initial)
    expect(fb.contains(Feedback.Led(Button.ModeKey(0), true))) and expect(fb.contains(Feedback.Led(Button.ModeKey(1), false)))
  }

  // "Switching modes repaints those lamps too"
  pureTest("a switch repaints the mode keys") {
    val (_, _, fb) = modes.step(modes.initial, Control.Press(Button.ModeKey(1), true))
    expect(fb.contains(Feedback.Led(Button.ModeKey(1), true))) and expect(fb.contains(Feedback.Led(Button.ModeKey(0), false)))
  }

  // "for every mode index i" — one lamp per mode
  pureTest("one mode-key lamp per mode") {
    val keys = modes.enter(modes.initial).collect { case Feedback.Led(Button.ModeKey(i), _) => i }
    expect(keys.sorted == List(0, 1))
  }

  // "Modes.single ... keep behaving as today"
  pureTest("single lights no mode key") {
    expect(!Modes.single(a).enter(a.initial).exists {
      case Feedback.Led(Button.ModeKey(_), _) => true
      case _                                  => false
    })
  }
