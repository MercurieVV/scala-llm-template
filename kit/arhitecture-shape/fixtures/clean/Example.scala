package example

/** The clean half of the fixture pair: allowlisted types only, and none of the
  * disallowed constructs — no `if`, no `match`, no `var`.
  *
  * A top-level `def` rather than an `object`: the rule polices object-valued
  * term references too, so a module's own `object Foo` is flagged unless the
  * module's own package prefix is in `allowedTypes` — which is what a project's
  * build wiring adds (see skreeep2's `ArchitectureShapeModule`).
  */
def greeting(who: String): String = "hello " + who
