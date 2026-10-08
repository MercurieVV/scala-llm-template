package com.github.mercurievv.skreeep2.control

/** The first mode: the desk is a mixer.
  *
  * A strip binds to an instrument by position — `strips(bank * perBank + strip)` — so only the bank moves; a song with more instruments than channels
  * needs nothing else, and an unreachable instrument just keeps its level.
  *
  * Commands are the **difference between two level maps**, not the control that arrived — what makes solo expressible at all: pressing one strip's
  * solo changes every other instrument's level, which "what I was just told" could not say.
  */
final class MixerMode(strips: Vector[String], perBank: Int) extends Mode:
  import MixerMode.*

  type State = Mixer

  val initial: Mixer = ???

  /** The full repaint: where every visible fader should stand, what every visible lamp should show, and whose name is on the display. */
  def enter(state: Mixer): List[Feedback] = ???

  def step(state: Mixer, control: Control): (Mixer, List[Command], List[Feedback]) = ???

object MixerMode:

  /** The desk's state, and nothing else's: which instrument is loud is a fact about this mixer, not about the song. */
  final case class Mixer(faders: Map[String, Double], muted: Set[String], soloed: Set[String], bank: Int) derives CanEqual

  /** Solo wins over mute, and a solo anywhere silences everything it does not name — the standard console rule, stated once so both `enter` and
    * `step` agree on it.
    */
  def levelOf(state: Mixer, name: String): Double = ???

  /** Every instrument's level, which is what a fresh engine needs to be told before anything has moved. */
  def levels(state: Mixer, strips: Vector[String]): Map[String, Double] = ???
