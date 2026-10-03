package com.github.mercurievv.skreeep2.control.midi

import com.github.mercurievv.skreeep2.control.{Control, Feedback}

/** The Mackie Control (MCU) protocol, as a [[SurfaceCodec]].
  *
  * A Behringer X-Touch in MCU mode speaks this, and so does most of the world's control surfaces — the device is nowhere in this file except in that
  * sentence. This is a protocol; the device is a string in a config file.
  *
  * The parts that matter:
  *   - a fader is **pitch bend** on the strip's own channel, 14-bit, `0 .. 16383`; channel 8 is the master fader, which this codec reports as strip 8
  *   - a button is a **note on**, velocity 127 for a press and 0 for a release, at a fixed note per function
  *   - a V-Pot and the jog wheel are **relative** CCs: bit 6 is the direction and the low six bits the number of detents, so a value has no absolute
  *     meaning at all
  *   - a lamp is the same note echoed back, and a motorised fader the same pitch bend
  *   - the scribble strips are SysEx, seven characters per strip
  *
  * Bytes are read through `& 0xFF` throughout: the JDK hands out `Byte`, MIDI means unsigned, and the two disagree above 127 — every status byte
  * there is.
  */
object Mcu extends SurfaceCodec:

  def decode(bytes: Array[Byte]): Option[Control] = ???

  def encode(feedback: Feedback): List[Array[Byte]] = ???
