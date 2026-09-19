package example

/** The clean half of the fixture pair: allowlisted types only, and none of the
  * disallowed constructs — no `if`, no `match`, no `var`.
  *
  * It declares an `object`, on purpose. A module's own `object Foo` is a
  * term-valued reference like any other, so the module's own package prefix has
  * to be in `allowedTypes` — that is the `example/` entry in this check's
  * default allowlist, and the `allowedTypes() :+ ownPackagePrefix` convention a
  * real consumer's build follows (skreeep2's `ArchitectureShapeModule`). With
  * that prefix in place a module's own definitions stay out of the report.
  */
object Example:
  def greeting(who: String): String = "hello " + who
