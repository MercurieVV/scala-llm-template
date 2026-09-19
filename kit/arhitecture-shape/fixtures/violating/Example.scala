package example

import java.time.Instant // not in the allowlist below

object Example:
  def render(flag: Boolean): Int = if flag then Instant.now().getNano else 0
