package com.github.mercurievv.skreeep2

import _root_.algebra.ring.Field
import com.github.mercurievv.skreeep2.audio.AudioConfig
import spire.implicits.*

case class GlobalData(
  audioConfig: AudioConfig)

/** What a signal can read while rendering one chunk: `globalTime` is absolute since stream start (envelopes key off it, since a strike time is
  * absolute), `chunkTime`/`chunkStart` are chunk-relative (what a carrier's phase is built on, so it needn't recompute from an unbounded number), and
  * `sampleIndex` is the exact integer sample position `0 … clipSize - 1`, needed by signals that hash rather than oscillate (see [[signals.Noise]])
  * and unrecoverable from `globalTime`.
  */
//todo rename to GlobalValues
case class GloabalSignals[T](
  audioConfig: AudioConfig,
  globalTime: T,
  beatTime: T, // TODO: think how to move to loacal places
  globalTime2Pi: T,
  chunkStart: T,
  chunkTime2Pi: T,
  chunkDuration: T,
  sampleIndex: T)

/** The parts of [[GloabalSignals]] constant across every chunk. Rebuilding `sampleIndex`/`chunkDuration` per chunk measured at ~10µs — more than
  * every stage after `mix` combined — so this is built once per player and threaded in instead.
  */
final case class GlobalConstants[T](
  audioConfig: AudioConfig,
  pi2: T,
  sampleIndex: T,
  chunkDuration: T)

object GlobalConstants:

  def of[T: Conversion[Seq[Double], _]](audioConfig: AudioConfig, pi2: T): GlobalConstants[T] =
    GlobalConstants(
      audioConfig   = audioConfig,
      pi2           = pi2,
      sampleIndex   = Range(0, audioConfig.clipSize).map(_.toDouble),
      chunkDuration = Seq.fill(audioConfig.clipSize)(audioConfig.clipSize.toDouble / audioConfig.SAMPLE_RATE.toDouble),
    )

object GloabalSignals:

  /** Convenience form that also builds the per-chunk constants; the render loop should hold a [[GlobalConstants]] directly instead. */
  def create[T: {Field, Conversion[Seq[Double], _]}](audioConfig: AudioConfig, Pi2V: T)(off: T, chunkStartSeconds: Double): GloabalSignals[T] =
    create(GlobalConstants.of[T](audioConfig, Pi2V))(off, chunkStartSeconds)

  def create[T: {Field, Conversion[Seq[Double], _]}](c: GlobalConstants[T])(off: T, chunkStartSeconds: Double): GloabalSignals[T] =
    val start: T = Seq.fill(c.audioConfig.clipSize)(chunkStartSeconds)
    GloabalSignals(
      audioConfig   = c.audioConfig,
      globalTime    = off,
      beatTime      = off,
      globalTime2Pi = off * c.pi2,
      chunkStart    = start,
      chunkTime2Pi  = (off - start) * c.pi2,
      chunkDuration = c.chunkDuration,
      sampleIndex   = c.sampleIndex,
    )

case class ForTime[Time, SampleNumber](
  time: Time,
  sampleNumber: SampleNumber)

object ForTime:

  def byOffset[T: Conversion[Seq[Double], _]](offset: Long, audioConfig: AudioConfig): ForTime[T, T] =
    ???
