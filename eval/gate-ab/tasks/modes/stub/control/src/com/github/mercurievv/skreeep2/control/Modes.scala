package com.github.mercurievv.skreeep2.control

/** A mode is a [[Mode]], and so is a stack of them: switching is itself a mode, so nothing outside this file — codec, surface, wiring — has to know
  * there's more than one.
  *
  * Today a desk runs [[single]]. [[switching]]'s shape is why `Mode.State` is abstract, not concrete: two modes hold unrelated state, and a sequencer
  * must keep both without naming either.
  */
object Modes:

  /** One mode, unconditionally — the identity combinator, named so a call site reads as a deliberate choice, not an oversight. */
  def single(mode: Mode): mode.type = ???

  /** One mode at a time, chosen by [[Button.ModeKey]]. Each keeps its own state while another is current; a switch repaints via the new mode's
    * [[Mode.enter]] — a mode key never reaches the mode it selects.
    */
  def switching(modes: Vector[Mode]): Mode = ???

  /** Which mode is current, and every mode's state — including the ones that are not. A mode a desk comes back to should be where it was left. */
  final case class Switching(current: Int, held: Vector[Held])

  /** A mode packed with the state that belongs to *it*, checked at construction and unable to come apart: outside this file `Held.state` has no
    * nameable type, so nothing can feed one mode another's state.
    */
  sealed abstract class Held:
    val mode: Mode
    val state: mode.State

  object Held:

    def apply(m: Mode)(s: m.State): Held = ???
