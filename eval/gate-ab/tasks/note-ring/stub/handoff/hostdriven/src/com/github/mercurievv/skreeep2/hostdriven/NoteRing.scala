package com.github.mercurievv.skreeep2.hostdriven

final class NoteRing(capacity: Int) {

  /** Audio thread only. Returns false when the ring is full.
    *
    * Drops rather than blocks — not a shortcut: blocking the host's realtime thread on a thread-pool consumer is how a plugin causes a dropout in
    * every other track, and a dropped note is by far the smaller failure.
    */
  def offer(note: NoteRing.Raw): Boolean = ???

  /** Consumer thread only. Everything published since the last call, oldest first. */
  def drain(): Vector[NoteRing.Raw] = ???
}

object NoteRing:

  /** A host note as CLAP delivers it, stamped with the render time it arrived at.
    *
    * `atSamples` is load-bearing and must be read on the audio thread. Stamping at drain instead ties timing to a polling interval — sloppy in
    * realtime, and fatal offline: a bounce renders many blocks per poll, so a whole phrase collapses onto one instant. Measured: four notes half a
    * second apart came out as one burst.
    *
    * `sampleOffset` (position within its block) is kept but unused: onsets are still quantised to a block (11 ms at 512 frames, audible as slop on
    * percussion); using it means splitting the render at event boundaries.
    */
  /** What the ring carries: everything the host sends that this plugin reacts to.
    *
    * A sealed type, not a second ring for control changes — ordering: a mod wheel moving *between* two notes must arrive between them, and two rings
    * drained separately can't say which came first. One ring keeps the host's own, correct order.
    *
    * Both cases carry the same two clock fields, for the same reason [[RawNote]] always did.
    */
  sealed trait Raw:
    /** The note's position *within* its block, kept but not yet used — see [[RawNote]]. */
    def sampleOffset: Int

    /** The render time this event arrived at, stamped on the audio thread. */
    def atSamples: Long

  final case class RawNote(
    on: Boolean,
    key: Int,
    velocity: Double,
    sampleOffset: Int,
    atSamples: Long)
      extends Raw

  /** One MIDI control change: `controller` is the CC number, `value` normalised to 0..1.
    *
    * Normalised here, not in the song: 0..127 is a wire format a song shouldn't have to know. Which controller means what is the song's business,
    * stated in its `HostEvents.Codec`.
    */
  final case class RawCc(controller: Int, value: Double, sampleOffset: Int, atSamples: Long) extends Raw
