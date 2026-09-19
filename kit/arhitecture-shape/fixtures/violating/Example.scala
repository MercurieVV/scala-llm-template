package example

import java.time.Instant // not in the allowlist below

object Example:
  def render(flag: Boolean): Int = if flag then Instant.now().getNano else 0
  def at(i: Instant): Int = i.getNano // the same disallowed type, written as a type
  def pick(): Int = scala.util.Random.nextInt() // a disallowed Scala object reached as a term
