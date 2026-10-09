package com.github.mercurievv.skreeep2.signals

import cats.Foldable
import cats.arrow.Arrow
import cats.syntax.foldable.*

import algebra.ring.Field
import spire.implicits.*
import spire.math.ConvertableTo

/** One partial of a harmonic stack: which multiple of the fundamental it is, and how loud. Frequency isn't stored since it can glide within a note;
  * phase isn't stored either — it lives in a [[Var]] cell, see [[Sine.sineCalc]].
  */
case class Sine[CALC](
  multiple: CALC,
  volume: CALC)

object Sine:

  /** A sample of the partial, given the phase it starts this chunk at: `sin(phi + 2*pi*f*(t - chunkStart))`, not `sin(2*pi*f*t)` with absolute `t`.
    * With a time-varying `f`, `2*pi*t*f(t)` is not the phase integral — its derivative gives instantaneous frequency `f(t) + t*f'(t)`, exaggerating a
    * glide more the longer the song has played, and scaled by `n` per partial so the stack detuned against itself mid-glide.
    */
  def sineCalc[T: {Field, spire.algebra.Trig}](a: Sine[T], frequency: T, phase: T, chunkTime2Pi: T): T =
    ???

  /** The phase one chunk later, folded back into a single turn. The advance is constant across the chunk because the frequency law is sampled once at
    * chunk start, giving a single write-back value, which is what the device requires (one work-item writes, every work-item reads). The wrap is not
    * cosmetic: an unwrapped accumulator loses precision, costing the top partials their pitch within seconds in the kernel's single precision.
    */
  def advance[T: {Field, Modulo}](frequency: T, twoPi: T, chunkDuration: T, phase: T): T =
    ???

def slide(using t: TypeSystemValues, F: Field[t.Value], ARR: Arrow[t.==>])(startFreq: t.Value) =
  import t.*
  ARR.lift { (gd: Input) =>
    val time = gd.beatTime
    startFreq / time // (time / ((1024L * 100) + 1))
  }

object SinesGenerator:

  /** How many partials a default harmonic stack has. 24, not 50: this was chosen back when [[createSines]]'s `cnt` was the exclusive bound of the
    * *multiples* (50 gave 24 partials at 2f…48f) — now that `cnt` means what it says, restated in the same units so stacks don't silently double.
    */
  val DefaultSinesCount: Int = 24

  /** `cnt` partials at 2f, 4f, 6f… of the fundamental, each with amplitude `vol / multiple`, paired with the id of the cell that carries its phase.
    * Ids are positional (stable across chunks/notes), so two stacks in one voice must not share an `idBase`.
    *
    * **`cnt` is the number of partials.** It used to be the exclusive upper bound of the *multiples*, a different and roughly halved quantity —
    * `cnt = 2` used to give zero partials (silent, not thin), which is how `Drums.scala`'s kick went inaudible without anything failing.
    */
  def createSines[T: {Field, ConvertableTo}](vol: T, cnt: Int, idBase: VarId): List[(VarId, Sine[T])] =
    List.tabulate(cnt) { idx =>
      val vd = ConvertableTo[T].fromDouble(2.0 * (idx + 1))
      (idBase + idx, Sine(multiple = vd, volume = vol / vd))
    }

  /** A stack written out: each partial's multiple of the fundamental and its own amplitude, in the caller's order. [[createSines]] can only describe
    * a harmonic `1/n` series, so an inharmonic set (e.g. a 808 cymbal) must have its ratios given rather than generated.
    */
  def fromRatios[T, S[_]](ratios: S[(T, T)], idBase: VarId)(using Foldable[S]): List[(VarId, Sine[T])] =
    ratios.toList.zipWithIndex.map { case ((multiple, volume), idx) =>
      (idBase + idx, Sine(multiple = multiple, volume = volume))
    }

  /** The odd harmonics of a square wave, `count` of them, amplitude `1/k`. `from` skips the first harmonics, expressing a brickwall high-pass by
    * omission since there are no filters (ADR-012) — cheaper than generating and removing them.
    */
  def square[T: ConvertableTo](count: Int, from: Int): Seq[(T, T)] =
    Range(from | 1, (from | 1) + count * 2, 2).map(k => (ConvertableTo[T].fromDouble(k.toDouble), ConvertableTo[T].fromDouble(1.0 / k)))

  /** `cnt` partials clustered around the fundamental (`multiple = 1`), spread symmetrically by `spread` per step and each carrying `vol / cnt`.
    * Pushing multiples off the integer lattice [[createSines]]/[[square]] use makes them beat against each other — detuned-unison/"supersaw"
    * thickening. Volume is split `cnt` ways so a wider cluster doesn't also get louder.
    */
  def detuned[T: {Field, ConvertableTo}](vol: T, cnt: Int, spread: T, idBase: VarId): List[(VarId, Sine[T])] =
    val n = ConvertableTo[T].fromDouble(cnt.toDouble)
    Range(0, cnt).toList.map { idx =>
      val offset = ConvertableTo[T].fromDouble(idx.toDouble - (cnt - 1) / 2.0)
      val mult = Field[T].one + offset * spread
      (idBase + idx, Sine(multiple = mult, volume = vol / n))
    }
