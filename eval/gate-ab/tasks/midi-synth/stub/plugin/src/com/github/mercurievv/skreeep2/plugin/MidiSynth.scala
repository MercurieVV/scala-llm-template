package com.github.mercurievv.skreeep2.plugin

import cats.data.State

/** Voice allocation for host notes, keyed by pitch instead of `Perform.synthesizer`'s round-robin: a note-off must reach the voice its note-on took,
  * and pitch is the only identity `Struck` carries (ADR-001). Limit: two simultaneous notes at the same pitch share one voice and the second
  * retriggers the first, ordinary monophonic-per-pitch behaviour — distinguishing them would need a note id added to `Struck`.
  */
object MidiSynth:

  /** Which pitch owns which slot, and where the round-robin is. */
  final case class Allocation(byPitch: Map[Double, Int], next: Int)

  object Allocation:
    val empty: Allocation = Allocation(Map.empty, 0)

  /** Assigns `pitch` a slot, reusing the one it already holds. When a new pitch steals another's slot, the old pitch's claim is dropped so its later
    * note-off cannot silence the new note.
    */
  def allocate(pitch: Double, polyphony: Int): State[Allocation, Int] = ???
