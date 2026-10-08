package com.github.mercurievv.skreeep2.signals

import algebra.ring.Field
import spire.math.ConvertableTo

/** White noise, as integer arithmetic done in floating point. The kernel computes in single precision (ADR-008) while Breeze computes in double, so
  * every intermediate must stay an integer strictly below 2^23 (exactly representable in `float`) — otherwise the two backends' noise would diverge
  * and be un-testable against each other. All bounds are asserted in `NoiseSpec`.
  *
  * Two frequencies of variation (ADR-010): the seed advances once per launch (a `Var` cell — an update may not depend on the sample index, ADR-012),
  * and the sample index mixes in per work-item.
  */
object Noise:

  /** The number of distinct output levels: ~11 bits, inaudible under a percussive envelope. Raising it means raising the primes, capped by `< 2^23`.
    */
  val Levels: Int = ???

  /** Every product this file forms, so a test can assert the bound rather than trust the comments. */
  def products: Seq[Double] = ???

  def exactBound: Double = ???

  /** The seed one chunk later. Depends on nothing but itself, which is what makes it legal as a cell update — `Formula` rejects an update that reads
    * the sample index, since the device writes a cell from one work-item while every work-item reads it.
    */
  def advance[T: {Field, Modulo, ConvertableTo}](seed: T): T = ???

  /** One sample, in `[-1, 1)`. `index` is the chunk-relative sample number. The leading `mod(_, P1)` bounds the input before the first multiply, so
    * the `< 2^23` guarantee holds for any clip size, not just the current 128.
    */
  def sample[T: {Field, Modulo, ConvertableTo}](seed: T, index: T): T = ???
