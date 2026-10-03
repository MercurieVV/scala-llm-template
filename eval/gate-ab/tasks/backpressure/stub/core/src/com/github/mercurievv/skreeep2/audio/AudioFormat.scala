package com.github.mercurievv.skreeep2.audio

import scala.concurrent.duration.*

import cats.effect.kernel.Async

import fs2.Pipe

import com.github.mercurievv.MaxVolume
import com.github.mercurievv.skreeep2.PureKernels

/** The audio *format* — what a sample is, what a chunk is, how bytes reach a device; nothing here knows about a signal, voice or mixer. Split out of
  * `AudioPlayerResource` to break an import cycle (`GloabalSignals` needs `AudioConfig`, `Diagnostics` wraps `AudioSink`), keeping the same
  * `…skreeep2.audio` package so no import elsewhere had to change.
  */
val CLIP_SIZE = 128

/** `clipSize` is **frames**, not samples — a chunk is `clipSize * channels * bytesVol` bytes. `channels` is 1 unless asked for more; above 1 the
  * device is fed one stem per channel (see `AudioPlayerResource`).
  */
case class AudioConfig(
  SAMPLE_RATE: SampleRate,
  clipSize: Int,
  bytesVol: Int,
  maxVolume: MaxVolume,
  channels: Int)

object AudioConfig:

  /** What the engine plays at unless told otherwise — a named value, not defaulted parameters, so a caller wanting something else must say which. */
  val default: AudioConfig = AudioConfig(
    SAMPLE_RATE = SampleRate(44100),
    clipSize    = CLIP_SIZE,
    bytesVol    = 2,
    maxVolume   = MaxVolume(Short.MaxValue.toDouble),
    channels    = 1,
  )

opaque type SampleRate <: Int = Int

object SampleRate:
  def apply(v: Int): SampleRate = v

/** How long `frames` audio frames take at the configured sample rate; parameter is frames, not bytes. Nanosecond precision matters: a 128-frame chunk
  * at 44.1kHz is 2.902ms, which whole-millisecond math truncates to 2ms. The arithmetic is the Stainless-verified kernel `PureKernels.framesToNanos`.
  */
def framesToTime(audioConfig: AudioConfig, frames: Int): FiniteDuration =
  PureKernels.framesToNanos(frames, audioConfig.SAMPLE_RATE).nanos

/** One sample at output scale, signed 16-bit, saturating rather than wrapping. `Double.toShort` truncates the integer (33000 → -32536), turning a
  * near-full-scale peak into an opposite-sign full-scale click at the loudest, least maskable moment — found via a stem-vs-master diff (13 samples
  * off by exactly 65535 in 12s of an 808 kit) that nothing else in the trace would have shown. The body is the Stainless-verified kernel
  * `PureKernels.toPcm16` (NaN → 0).
  */
def toPcm16(v: Double): Short = PureKernels.toPcm16(v)

trait AudioSink[F[_]]:
  def write(buf: Array[Byte]): F[AudioSink.WriteResult]

object AudioSink:

  /** `availBefore`/`framePosition` are OS-maintained device counters, accurate across a JVM stop-the-world pause — the only trustworthy dropout
    * evidence (`availBefore == bufferSize` means the ring drained; `framePosition` vs. frames written gives the exact deficit).
    */
  case class WriteResult(
    len: Int,
    written: Int,
    avail: Int,
    bufferSize: Int,
    availBefore: Int,
    framePosition: Long)

/** Backpressure policy and pipe — independent of any signal type system. */
object AudioBuffer:

  /** How long to sleep after a write: back off when the buffer's nearly full (`avail < len`), slow down when over 8 chunks are queued ahead
    * (`bufferSize - avail > len*8`), otherwise write immediately. The sleep is one chunk minus `elapsed` already spent this cycle — omitting that
    * subtraction caused a confirmed ~1.5-2ms overshoot per cycle tracking render cost; `len`/`avail`/`bufferSize` are bytes, so converting through
    * `channels` matters, since a stereo chunk doubles the bytes per duration and skipping it silently doubled the sleep once already.
    */
  def backpressureDelay(config: AudioConfig, wr: AudioSink.WriteResult, elapsed: FiniteDuration): Option[FiniteDuration] = ???

  def pipe[F[_]: Async](config: AudioConfig, sink: AudioSink[F]): Pipe[F, Array[Byte], Unit] = ???
