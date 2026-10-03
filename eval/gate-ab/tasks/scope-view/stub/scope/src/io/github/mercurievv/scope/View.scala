package io.github.mercurievv.scope

/** The window onto the curve: which x range and which y range are on screen.
  *
  * Everything here is pure arithmetic — no Swing, no drawing — so the zoom/pan/tick logic can be tested without a display.
  */
final case class View(x0: Double, x1: Double, y0: Double, y1: Double) derives CanEqual:

  def spanX: Double = ???
  def spanY: Double = ???

  /** Zoom about a fixed world point: `about` keeps its screen position, which is what makes wheel-zoom-at-cursor feel right. `factor` < 1 zooms in.
    */
  def zoomX(factor: Double, about: Double): View = ???
  def zoomY(factor: Double, about: Double): View = ???
  def zoom(factor: Double, aboutX: Double, aboutY: Double): View = ???

  /** Move the window by a world-space delta (drag-pan converts pixels to world first). */
  def panBy(dx: Double, dy: Double): View = ???

  def withY(ny0: Double, ny1: Double): View = ???

  /** Repair a degenerate or inverted range so the transforms never divide by zero. */
  def sane: View = ???

object View:

  val unit: View = ???

  /** Headroom around fitted data: 8% of its range. */
  val DefaultPad: Double = ???

  /** A y range that contains `values` with a little headroom; flat data still gets a usable range. */
  def fitY(values: Iterable[Double], pad: Double): (Double, Double) = ???

  /** The 1/2/5×10^k step nearest to `raw` from below — the step size that makes axis labels readable at any decade. */
  def niceStep(raw: Double): Double = ???

  /** Tick positions inside `[a, b]`, aiming for about `target` of them, snapped to 1/2/5×10^k multiples. */
  def ticks(a: Double, b: Double, target: Int): Vector[Double] = ???

  /** Label a tick with just enough decimals for `step` to be distinguishable. */
  def label(t: Double, step: Double): String = ???

/** The pixel rectangle a view is drawn into, and the two transforms between it and world coordinates.
  *
  * `y` is flipped: world y grows upward, screen y grows downward.
  */
final case class Axes(
  px: Int,
  py: Int,
  pw: Int,
  ph: Int,
  view: View)
    derives CanEqual:

  def screenX(wx: Double): Double = ???
  def screenY(wy: Double): Double = ???

  def worldX(sx: Double): Double = ???
  def worldY(sy: Double): Double = ???
