# AllowedShape

The kit's L2 enforcement rule: one scalafix `SemanticRule` that decides, for a module, **which types it may
name** (an allowlist) and **which constructs it may use** (a denylist). It is the machine half of R-2 ("the
abstract level names no concrete type; it reaches outside its package only through an explicit allowlist") and
R-3 ("nothing imperative where the type system can state it").

The rule is **vendored, not published**: every adopting project copies this directory, and `check.sh` is the
proof that the copy still discriminates. A project may tune its copy — that is what vendoring is for.

## What the rule decides

| # | Mechanism | What it flags |
|---|---|---|
| 1 | Referenced types | Every `Type.Name` outside an `import`, unless it is the name *being defined* (`trait Foo`, `type Event = ...`) or a type-parameter binder / compiler-synthesized local. |
| 2 | Object-valued terms | Every `Term.Name` whose symbol is an object — `Kleisli.catsDataArrowChoiceForKleisli(...)` names `Kleisli` without ever writing it as a type, and `scala.util.Random.nextInt()` names the `Random` object. A module's own `object Foo` is included: the module's own package prefix has to be in `allowedTypes` (a project's build adds it). Only `.`-terminated object symbols qualify — a class (`#`) symbol used as a term is not caught here (see the named blind spot under R-11). |
| 3 | Importees | Every `Importee.Name`/`Importee.Rename` that names a type or an object, so a disallowed type fails at the line stating intent to use it. A method or `val` import (`toFunctorOps`) is syntax, not policy, and is not policed. |
| 4 | Constructs | Every tree whose scalameta node kind is listed in `disallowedConstructs` (`TermIf`, `TermMatch`, `DefnVar`, …). Kind names are node class names with the generated `Impl` suffix stripped. |

Allowlist entries are **symbol prefixes**: `cats/arrow` allows everything under it, `scala/Int` allows
`scala/Int#`. A symbol is allowed when its value starts with an entry.

Two conventions follow from the table, and both are what a real consumer's build does:

- **Append the module's own package prefix to `allowedTypes`.** `check.sh`'s default allowlist carries
  `example/` for exactly that reason, and skreeep2's Mill helper spells the convention out as
  `allowedTypes() :+ ownPackagePrefix` (`buildKit/ArchitectureShapeModule.mill:56`). Without that prefix the
  rule reports the module's own `object Foo` — and its own types, when they are referenced rather than
  defined — as references to something disallowed.
- **Read mechanism 2 as "object symbols", not as "every term reference".** A Java class's static member
  reached without an import (`java.time.Instant.now()`) resolves to a class (`#`) symbol and is caught by
  neither mechanism 2 nor mechanism 3. That gap is named under R-11 below; it is a property of the canonical
  rule, which this copy does not alter.

## Configuration

Two keys, spelled exactly like this, under an `AllowedShape` section:

```hocon
AllowedShape {
  allowedTypes = [
    "scala/Predef.String",
    "scala/Int",
    "cats/arrow",
    "com/example/myapp/mymodule/"   # the module's own package prefix
  ]
  disallowedConstructs = [
    "TermIf", "TermMatch", "TermWhile", "TermFor", "TermTry", "TermThrow",
    "TermReturn", "LitNull", "DefnVar", "DeclVar", "Case"
  ]
}
```

`allowedTypes` / `disallowedConstructs` and the rule name `AllowedShape` are the **frozen interface** —
recipes, build wiring and later tasks depend on those three spellings. An empty `allowedTypes` disables the
type half (the rule then checks constructs only); an empty `disallowedConstructs` checks types only.

**Policy lives in each project's build, never in the rule file.** `AllowedShape.scala` is a verbatim copy of
the canonical rule; its only difference is the `package` line, which is
`io.github.mercurievv.arhitecture.scalafix` (the canonical source lives in the reengineering session's
`scalafixRules/src/AllowedShape.scala` under `package skreeep2.scalafix`). The allowlist, the denylist and the
own-package prefix are supplied by the project's build (skreeep2 wires them in
`buildKit/ArchitectureShapeModule.mill`; a Mill/`scalafixRules` layout puts this rule in
`scalafixRules/src/AllowedShape.scala` and the registration in
`scalafixRules/resources/META-INF/services/scalafix.v1.Rule`). Keeping policy out of the rule file is what
makes a later move to a published artifact a dependency change instead of a rewrite.

The rule name is resolved through `META-INF/services/scalafix.v1.Rule`, which must contain exactly one line:
the fully-qualified class name. Drop it and `--rules AllowedShape` fails with `Unknown rule 'AllowedShape'`.

## SemanticDB is not optional

Mechanism 1–3 are guarded by `t.symbol.value.nonEmpty`. A run without SemanticDB is not a clean run: the
rule does not run at all, so the report says nothing about the allowlist. **A silent pass is not a pass** —
that is the R-8 point this section exists for. The two failure modes measured with the CLI are both
silent-looking:

- `--syntactic` (semantic rules ignored): prints `No rules requested to run` and **exits 0**.
- a classpath whose compiled output has no `META-INF/semanticdb`: exits 8, `SemanticDB not found`.

So: compile the sources under check with SemanticDB, and put that compiled output on the CLI's `--classpath` —
scalafix reads SemanticDB from the classpath, which is how Mill passes `semanticDbData()`. The spellings that
work:

- **scala-cli:** `--semanticdb --semanticdb-sourceroot <dir>` — what `check.sh` uses.
- **raw scalac:** `-Xsemanticdb -semanticdb-target <classes dir>`. Without the target flag the semanticdb file
  lands *beside the source* rather than in the output directory, and the CLI answers `SemanticDB not found`.
  (Passed through scala-cli those two options need `-O`, which only forwards `-g`/`-language`/`-opt`/`-P`/
  `-target`/`-V`/`-W`/`-X`/`-Y` options implicitly.)
- **Mill/sbt:** the same two scalac options, with the compiled output handed to the rule's classpath.

`--sourceroot` must be the directory the stored paths are relative to — the same directory given as
`--semanticdb-sourceroot` (or `-sourceroot`) when compiling.

## `check.sh`

```sh
sh check.sh                       # defaults: stdlib + `example/` allowlist, TermIf
sh check.sh "<allowed types>" "<disallowed constructs>"
ALLOWED_TYPES="..." DISALLOWED_CONSTRUCTS="..." sh check.sh
```

Requires `scala-cli` (compiler driver) and `cs` (coursier, to launch the scalafix CLI); no build tool and no
build file is added to the project. `scala-cli` is always invoked with `--server=false`, so the check is
non-interactive and needs no Bloop daemon.

What it does:

1. compiles the vendored `AllowedShape.scala` against `ch.epfl.scala:scalafix-rules_3.8.4:0.14.7`;
2. builds a tool classpath from those classes plus this directory's `META-INF/services` registration;
3. compiles each fixture with SemanticDB under `fixtures/`, asserting the `.semanticdb` file exists;
4. runs `cs launch ch.epfl.scala:scalafix-cli_3.8.4:0.14.7 --main-class scalafix.cli.Cli -- --tool-classpath
   … --rules AllowedShape --config … --classpath … --sourceroot … --check <fixture>` for each fixture;
5. asserts the CLI's own exit status per fixture (64 with diagnostics under `--check`, 0 on the clean
   fixture — 8 and 4 get their own messages), then counts the diagnostics **per mechanism** — type
   references, importees, object-valued terms and constructs, read off the messages the rule emits — prints
   that attribution, and asserts it.

Measured with the committed fixtures (scala-cli 3.8.4, scalafix 0.14.7):

```
violating: 4 diagnostics [type references 1, importees 1, object-valued terms 1, constructs 1]
clean: 0 diagnostics [type references 0, importees 0, object-valued terms 0, constructs 0]
```

The violating fixture's four diagnostics are one per mechanism, so deleting any single mechanism's code path
changes an asserted number: `def at(i: Instant)` writes a disallowed type *as a type* (mechanism 1),
`import java.time.Instant` names it as an importee (mechanism 3), `scala.util.Random` is a genuine object
symbol reached as a term (mechanism 2 — unlike `Instant.now()`, whose `Instant` is a class symbol), and the
`if` is a denylisted construct (mechanism 4). The clean fixture declares its own `object Example` and still
reports nothing, which is the other half of the pair: the own-package prefix keeps a module's own definitions
out of the report.

Every run prints the diagnostics it saw, the CLI's exit status and the counts it measured. `check.sh`'s own
exit status separates three cases: **0** the fixtures behaved; **1** the check ran and the artifact did not
behave (missing registration, a missing fixture, a fixture that does not compile, a CLI failure, a count that
moved); **2** the check could not be set up on this machine (no work directory, `scala-cli` or `cs` missing,
or the rule did not compile against the scalafix-rules artifact — on a cold cache or without network, that
last one is the environment talking). The CLI's status is asserted rather than merely printed, because a
failed run's output is empty: counting alone would read it as "no findings", which is the silent pass this
whole check exists to prevent.

Intermediate output goes to a temporary directory (removed on exit); set `ALLOWED_SHAPE_WORKDIR=<dir>` to keep
it somewhere inspectable. Overriding `ALLOWED_TYPES`/`DISALLOWED_CONSTRUCTS` moves the measured counts, and
the script will say so: the expectations are constants *in the file*, re-measured deliberately when the rule,
the fixtures or the policy move — never lowered, and never "fixed" by widening the allowlist or bumping a
threshold (R-10). A fixture that stops discriminating is a defect to report, not to paper over (R-8).

## What this rule is not (R-11)

Decidable, and therefore this rule's business: a concrete type outside the allowlist; a construct on the
denylist; a missing registration; a run with no SemanticDB.

Judgement, and therefore not this rule's business: whether the split is the right one; whether a component
*named* a shape or spelled one; whether a contract is honest; whether a divergence is a fix or a design
change. A green `check.sh` says the machinery works — it says nothing about the design, and must never be
used as if it did.

### Named blind spot: a type reached as a fully-qualified static term

What the rule decides has an edge, and the edge is written down here rather than left to be discovered.
Measured 2026-09-19 (Scala 3.8.4, scalafix 0.14.7); **not fixed in this copy**, because the rule is vendored
verbatim and a canon that silently diverges from the session's own copy is the thing the design's
extraction trigger governs (R-10: escalate, never patch around it):

```scala
package example

object Probe:
  def value: Int = java.time.Instant.now().getNano   // no `import java.time.Instant`
```

`Instant` here is a `Term.Name` whose symbol is `java/time/Instant#` — a **class** symbol. The importee check
(mechanism 3) never sees it, because there is no import to flag; the object-valued-term check (mechanism 2)
passes over it, because that mechanism accepts only `.`-terminated object symbols. The line therefore
produces **no diagnostic**, while the same type imported or written as a type does.

Practical consequence: a module can reach a Java type's statics without tripping the allowlist, provided it
never imports the type and never writes it as a type. Where that matters, the rule cannot be the only thing
standing between the module and the type — that residue is judgement, and belongs to the review lane (R-9),
not to a widened allowlist. Closing the gap means changing the rule's logic: a kit-level behaviour change
(the design's extraction trigger), not an edit to a vendored copy.

## Files

| File | Role |
|---|---|
| `AllowedShape.scala` | the canonical rule, vendored verbatim (package line differs) |
| `META-INF/services/scalafix.v1.Rule` | the registration: `--rules AllowedShape` resolves through it |
| `check.sh` | compiles rule + fixtures with SemanticDB, runs the CLI, asserts the counts |
| `fixtures/violating/Example.scala` | must produce an importee diagnostic, an object-valued-term diagnostic *and* a construct diagnostic |
| `fixtures/clean/Example.scala` | declares its own `object`, uses allowlisted types only, must produce none |
