package com.github.mercurievv.skreeep2.signals.envelopes

import io.github.mercurievv.spireopencl.algebra.OrderS

import algebra.ring.Field

/** Attack-Decay-Sustain-Release shape: ramp 0→1 over `attack`, 1→`sustainLevel` over `decay`, flat over `sustain`, then `sustainLevel`→0 over
  * `release`. `duration` is the note's whole step (attack+decay+sustain); a note shorter than `attack + decay` never reaches sustain.
  */
case class ADSR[T](
  attack: T,
  decay: T,
  duration: T,
  release: T,
  sustainLevel: T,
)(using F: Field[T],
  O: OrderS[T])
    extends Shape[T]:

  override def amplitudeAt(globalTime: T, startTime: T): T =
    ???
