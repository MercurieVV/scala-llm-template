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
| 2 | Object-valued terms | Every `Term.Name` naming an object — `Kleisli.catsDataArrowChoiceForKleisli(...)` names `Kleisli` without ever writing it as a type. A module's own `object Foo` is included: the module's own package prefix has to be in `allowedTypes` (a project's build adds it). |
| 3 | Importees | Every `Importee.Name`/`Importee.Rename` that names a type or an object, so a disallowed type fails at the line stating intent to use it. A method or `val` import (`toFunctorOps`) is syntax, not policy, and is not policed. |
| 4 | Constructs | Every tree whose scalameta node kind is listed in `disallowedConstructs` (`TermIf`, `TermMatch`, `DefnVar`, …). Kind names are node class names with the generated `Impl` suffix stripped. |

Allowlist entries are **symbol prefixes**: `cats/arrow` allows everything under it, `scala/Int` allows
`scala/Int#`. A symbol is allowed when its value starts with an entry.

Measured boundary of mechanism 2 (2026-09-19, scalafix 0.14.7): a *Java* class's static member —
`java.time.Instant.now()` — resolves its term to the class symbol `java/time/Instant#`, not to an object
symbol, so the term occurrence is **not** flagged; the `import java.time.Instant` line is what catches it
(mechanism 3). A Scala object (`scala.util.Random`) is flagged at the term. Do not read mechanism 2 as
"every term reference is checked".

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

Mechanism 1–3 are guarded by `t.symbol.value.nonEmpty`. A run without SemanticDB is not a clean run — it is
an unrun rule, and the two failure modes measured with the CLI are both silent-looking:

- `--syntactic` (semantic rules ignored): prints `No rules requested to run` and **exits 0**.
- a classpath whose compiled output has no `META-INF/semanticdb`: exits 8, `SemanticDB not found`.

So: compile the sources under check with `-Xsemanticdb` (scala-cli: `--semanticdb`), and put that compiled
output on the CLI's `--classpath` — scalafix reads SemanticDB from the classpath, which is how Mill passes
`semanticDbData()`. `--sourceroot` must be the directory the stored paths are relative to.

## `check.sh`

```sh
sh check.sh                       # defaults: stdlib allowlist + TermIf
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
5. counts `[AllowedShape.disallowedType]` / `[AllowedShape.disallowedConstruct]` lines in that output,
   prints them, and asserts them.

Measured with the committed fixtures (scala-cli 3.8.4, scalafix 0.14.7):

```
violating: 3 diagnostics (2 disallowedType, 1 disallowedConstruct)
clean: 0 diagnostics (0 disallowedType, 0 disallowedConstruct)
```

The two type diagnostics on the violating fixture are the `import java.time.Instant` (mechanism 3) and the
fixture's own `object Example` (mechanism 2) — *not* `Instant.now()`'s term, see the boundary above. Every
run prints the diagnostics it saw and the counts it measured; exit status is 0 when the fixtures behave, 1
when they do not (including a missing fixture), 2 when the script cannot set itself up.

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

## Files

| File | Role |
|---|---|
| `AllowedShape.scala` | the canonical rule, vendored verbatim (package line differs) |
| `META-INF/services/scalafix.v1.Rule` | the registration: `--rules AllowedShape` resolves through it |
| `check.sh` | compiles rule + fixtures with SemanticDB, runs the CLI, asserts the counts |
| `fixtures/violating/Example.scala` | must produce a type diagnostic *and* a construct diagnostic |
| `fixtures/clean/Example.scala` | must produce none |
