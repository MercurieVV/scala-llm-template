package com.github.mercurievv.skreeep2.control

import weaver.*

/** Authored for the gate feature-request study (spec 2026-10-10); each test names the request sentence it checks. */
object ExclusiveSoloSpec extends SimpleIOSuite:

  private val band = Vector("kick", "snare", "bass")

  private def last(mode: MixerMode, cs: List[Control]): (MixerMode.Mixer, List[Command], List[Feedback]) =
    cs.foldLeft((mode.initial, List.empty[Command], List.empty[Feedback])) { case ((s, _, _), c) => mode.step(s, c) }

  private val excl = MixerMode.exclusive(band, 3)

  // "soloing an instrument clears every other solo, and the solo lamps ... whose solo was cleared go dark"
  pureTest("a second solo replaces the first") {
    val (_, cs, fb) = last(excl, List(Control.Press(Button.Solo(0), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("kick", 0.0), Command.SetLevel("snare", 1.0))) and
      expect(fb.contains(Feedback.Led(Button.Solo(0), false))) and expect(fb.contains(Feedback.Led(Button.Solo(1), true)))
  }

  // "Pressing the solo of the only soloed instrument un-solos it"
  pureTest("pressing the only solo again un-solos it") {
    val (_, cs, _) = last(excl, List(Control.Press(Button.Solo(1), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("kick", 1.0), Command.SetLevel("bass", 1.0)))
  }

  // "new MixerMode(strips, perBank) keeps today's behaviour": solos add up
  pureTest("a plain mixer's solos add up") {
    val (_, cs, _) = last(new MixerMode(band, 3), List(Control.Press(Button.Solo(0), true), Control.Press(Button.Solo(1), true)))
    expect(cs == List(Command.SetLevel("snare", 1.0)))
  }
