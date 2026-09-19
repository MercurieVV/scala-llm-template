# Recipe: Mill

Mill wiring for the kit's `AllowedShape` rule: the vendored rule on every shaped module's **tool classpath**, its two
config keys — `allowedTypes`, `disallowedConstructs` — generated **per module** from Mill tasks, and the command that
fails on a finding.

- **Prerequisites:** Mill 1.x with [`com.goyeau::mill-scalafix`](https://github.com/joan38/mill-scalafix) (measured
  here against 0.6.2 on Mill 1.1.8 and Scala 3.8.4, scalafix 0.14.7); the kit's `arhitecture-shape/` directory (the
  rule and its registration). No `scala-cli`, no `cs`, and no other build tool is involved.
- **What is frozen:** the rule name `AllowedShape`, the keys `allowedTypes` and `disallowedConstructs`, and the rule's
  own text. Everything below is wiring; none of it edits the rule file.

```
repo/
├── build.mill                            # the rule module, BuildPaths, the tool classpath, a shaped module  (1, 2, 4)
├── ScalafixExtra.mill                    # generic: extra rules + typed settings → a generated config  (step 3)
├── buildKit/
│   ├── package.mill                      # anchor file: Mill finds sibling .mill files only next to it
│   └── ArchitectureShapeModule.mill      # the kit's helper, copied here  (step 4)
├── scalafixRules/
│   ├── src/AllowedShape.scala            # the rule, verbatim from kit/arhitecture-shape/
│   └── resources/META-INF/services/scalafix.v1.Rule
└── .scalafix.conf                        # the project's own ruleset — the helper `include`s it  (step 4)
```

The build-side code blocks below are **fragments of the same `build.mill`, in the order they appear** (steps 1, 2 and
4); step 3 is `ScalafixExtra.mill`, and step 4 also copies the helper and the anchor file. Nothing else is added to
the build — every symbol the fragments use is defined in one of them.

## 1. Put the rule in its own module

`scalafixRules/src/AllowedShape.scala` is `kit/arhitecture-shape/AllowedShape.scala` copied as-is; the kit's
`META-INF/services/scalafix.v1.Rule` goes to `scalafixRules/resources/META-INF/services/scalafix.v1.Rule` (Mill copies
`resources/` into the module's output, which is how `--rules AllowedShape` finds the class — drop it and scalafix
answers `Unknown rule 'AllowedShape'`).

`build.mill`, head of the file — Mill reads the build's own dependencies from the `//|` header, and that header must
be the file's first lines (a comment line above it fails with `YAML header comments can only occur at the start of the
file`):

```scala
//| mvnDeps:
//| - com.goyeau::mill-scalafix::0.6.2
package build

import mill._
import mill.scalalib._
import com.goyeau.mill.scalafix.ScalafixModule
import build.buildKit.ArchitectureShapeModule

val scala3Version = "3.8.4"

/** Repo-global paths, resolved from Mill's own build root rather than a module's directory (modules sharing a base
  * directory collapse in an IDE import). An `object`, not a top-level `val`: only `object`/`class`/`trait` cross
  * sibling `.mill` files in Mill's file-based build — and the helper's `baseScalafixConfigFile` reads it.
  */
object BuildPaths {
  val repoRoot: os.Path = mill.api.BuildCtx.workspaceRoot
}

/** Project-local scalafix rules (`AllowedShape`), checked in-repo, never published. Not a shaped module itself:
  * it compiles the tool classpath those modules need, so it cannot lint itself.
  */
object scalafixRules extends ScalaModule {
  def scalaVersion = scala3Version
  def mvnDeps      = Seq(mvn"ch.epfl.scala:scalafix-rules_3.8.4:0.14.7")
}
```

The rule is a `SemanticRule` compiled against `scalafix-rules`; compile it against the same Scala and scalafix
versions whose CLI will load it (the plugin resolves the CLI from the linted module's `scalaVersion`), because the
rule's classes are loaded by that CLI's own classloader. The rule's imports (`scalafix.v1.*`, `metaconfig.*`,
`scala.meta.*`) are supplied at runtime by the CLI's parent classloader — see `kit/arhitecture-shape/check.sh` for the
same classpath shape measured against the CLI directly — so this is the only dependency the rule module needs.

## 2. Put the rule module on the tool classpath

`scalafixToolClasspath` is mill-scalafix's key for exactly this case — its own scaladoc: *"Extra entries appended to
Scalafix's tool classpath … Use this to load rules compiled in the same build — e.g. an in-repo rule module — without a
`publishLocal` round trip."* Since the rule is deliberately unpublished, this key is the mechanism, not
`scalafixIvyDeps` (which takes published artifacts only):

```scala
/** The project's own module trait — every shaped module extends it (directly or via more traits). */
trait Layer extends ScalaModule with ScalafixModule {
  def scalaVersion = scala3Version

  /** The rule is never published, so it rides the tool classpath rather than `scalafixIvyDeps`. */
  override def scalafixToolClasspath: T[Seq[PathRef]] =
    Task { super.scalafixToolClasspath() ++ Seq(scalafixRules.jar()) ++ scalafixRules.runClasspath() }
}
```

One stale note in the plugin's own scaladoc, worth knowing before you read it: it still says rule modules *"must
target Scala 2.13, since Scalafix loads rules through a 2.13 classloader regardless of the linted module's Scala
version"*. That predates scalafix 0.14.x's Scala 3 CLI: with a Scala 3 module the plugin classloads
`scalafix-cli_<scalaVersion>` (3.8.4 here), and a Scala 3 rule module compiled against
`scalafix-rules_<scalaVersion>` loads and runs — measured end to end, see the bottom of this recipe.

## 3. Generate the config, per module (generic plumbing)

scalafix's embedding API takes a config **path**, never a live settings object, so per-module policy means a generated
config file per module. Copy the file below to `ScalafixExtra.mill` at the repo root (Mill's build-script classpath
already provides `upickle`, which the derived `ReadWriter`s use). It knows nothing about `AllowedShape`: it layers
extra rules and typed settings on top of the module's own base config, which is what lets each module own its lists.

```scala
package build

import mill._
import com.goyeau.mill.scalafix.ScalafixModule

/** A typed HOCON value. A module states shape — `strs`, `bool`, a nested `obj` — instead of hand-interpolating text,
  * so a malformed array or an unescaped quote is a rendering bug in one place (`render`) rather than a risk at every
  * call site. Generic: it renders any HOCON value; `RuleSettings` is the part that assumes a scalafix rule's shape.
  */
enum ScalafixValue derives CanEqual, upickle.default.ReadWriter {
  case Str(value: String)
  case Bool(value: Boolean)
  case Num(value: Double)
  case Arr(values: Seq[ScalafixValue])
  case Obj(fields: Seq[(String, ScalafixValue)])
}

object ScalafixValue {
  def str(value: String): ScalafixValue                    = Str(value)
  def bool(value: Boolean): ScalafixValue                  = Bool(value)
  def num(value: Double): ScalafixValue                    = Num(value)
  def arr(values: Seq[ScalafixValue]): ScalafixValue       = Arr(values)
  def obj(fields: (String, ScalafixValue)*): ScalafixValue = Obj(fields)
  /** The common case: a plain list of strings, without wrapping each one in `str` at the call site. */
  def strs(values: Seq[String]): ScalafixValue = Arr(values.map(Str(_)))

  def render(value: ScalafixValue): String = value match {
    case Str(s)  => "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    case Bool(b) => b.toString
    case Num(n)  => if n == n.toLong then n.toLong.toString else n.toString
    case Arr(vs) => vs.map(render).mkString("[", ", ", "]")
    case Obj(fs) => fs.map((k, v) => s"$k = ${render(v)}").mkString("{ ", ", ", " }")
  }
}

/** One scalafix rule's settings, as typed fields rather than a pre-formatted config string. */
final case class RuleSettings(rule: String, fields: Seq[(String, ScalafixValue)]) derives upickle.default.ReadWriter {
  def render: String = fields.map((field, v) => s"$rule.$field = ${ScalafixValue.render(v)}").mkString("\n")
}
object RuleSettings {
  def of(rule: String, fields: (String, ScalafixValue)*): RuleSettings = RuleSettings(rule, fields)
}

/** Mix into any `com.goyeau.mill.scalafix.ScalafixModule` to activate extra scalafix rules and configure them from
  * plain Mill `T[...]` values, for *any* rule — this trait knows nothing about any specific rule.
  *
  * Still ends in a generated config file: `scalafix.interfaces` (the stable, cross-classloader embedding API every
  * build tool integration uses) only ever accepts a config *path*, never a live settings object. The one field that
  * would let a caller override individual rule settings without a hand-authored `.scalafix.conf` — the internal
  * `Args.settings: Conf` — sits behind `scalafix.internal`, a package with no compatibility promise, and still
  * bottoms out at a `metaconfig.Conf`, never a caller-defined case class: the runner discovers rules by name via
  * `ServiceLoader` and has no compile-time knowledge of any rule's config type by design. The file lives only in
  * Mill's own `Task.dest` (`out/<module>/scalafixConfig.dest/`, never checked in, cleaned by `mill clean`) and is
  * regenerated from these tasks every time.
  */
trait ExtraScalafixRules extends ScalafixModule {
  /** Rule names to activate on top of whatever the module's base config already runs. */
  def extraRules: T[Seq[String]] = Task(Seq.empty[String])

  /** Typed settings for the rules named in `extraRules` (or for any already-active rule — a settings-only override
    * needs no entry in `extraRules`). One `RuleSettings` per rule.
    */
  def extraRuleSettings: T[Seq[RuleSettings]] = Task(Seq.empty[RuleSettings])

  /** The ruleset this module already runs, before layering `extraRules` on top — typically the project's own
    * `.scalafix.conf`, or a per-flavour variant of it. No default: every project's base config lives somewhere
    * different, so a mixer must say where.
    */
  protected def baseScalafixConfigFile: os.Path

  override def scalafixConfig: T[Option[os.Path]] = Task {
    val rules    = extraRules()
    val settings = extraRuleSettings()
    if rules.isEmpty && settings.isEmpty then Some(baseScalafixConfigFile)
    else
      val generated = Task.dest / "extra-rules.conf"
      os.write(
        generated,
        s"""include file("${baseScalafixConfigFile.toString}")
           |${rules.map(r => s"rules += ${ScalafixValue.render(ScalafixValue.Str(r))}").mkString("\n")}
           |${settings.map(_.render).mkString("\n")}
           |""".stripMargin,
      )
      Some(generated)
  }
}
```

## 4. The helper, and how a module mixes it in

Copy the kit's `kit/recipes/mill/ArchitectureShapeModule.mill` to `buildKit/ArchitectureShapeModule.mill`, next to a
`buildKit/package.mill` containing just its package line — Mill discovers sibling `.mill` files only when the
directory has that anchor. The helper mixes `ExtraScalafixRules` in and names the rule; it takes three parameters:

| Parameter | Meaning |
|---|---|
| `def packageRoot: String` | required, `/`-separated with a trailing slash (`"com/example/myapp/"`); the module's own path from Mill's `moduleSegments` is appended to it, so it cannot drift from the module declaring it |
| `def baseAllowedTypes: T[Seq[String]]` | the allowlist every shaped module starts from (default: a minimal stdlib set) |
| `def disallowedConstructs: T[Seq[String]]` | the construct denylist (default: the kit's R-3 list) |

```scala
// build.mill (the file from steps 1 and 2, continued)
object engine extends Module {
  /** The abstract level: arrows and abstract types, nothing concrete. */
  object arhitecture extends Layer with ArchitectureShapeModule {
    def packageRoot = "com/example/myapp/"

    def baseAllowedTypes = Task(
      super.baseAllowedTypes() ++ Seq(
        "cats/arrow",                              // a prefix: everything under it is allowed
        "com/example/myapp/core/SharedShape",      // a type shared across the project's shaped modules
      )
    )

    // `disallowedConstructs` is deliberately not overridden here: omitting it inherits the helper's default — the
    // kit's R-3 list of node kinds — which is what a shaped module wants unless its own policy differs. When it
    // does, the difference is stated here, in this module's own list (R-10):
    //   def disallowedConstructs = Task(super.disallowedConstructs().filterNot(Set("TermIf")))
  }
}
```

`.scalafix.conf` at the repo root is the project's **own** ruleset — the helper `include`s it, so it has to exist.
Create it even if it is nearly empty; `AllowedShape` does not belong here, because the generated config adds it per
module:

```hocon
# .scalafix.conf — whatever the project already runs (OrganizeImports, DisableSyntax, …), or nothing yet.
# The shape rule's own settings are generated per module; this file is only included.
rules = []
```

What Mill renders for that module is `out/engine/arhitecture/scalafixConfig.dest/extra-rules.conf` — the base config,
plus the rule name, plus both keys, with the module's own package prefix appended to the allowlist:

```hocon
include file("/repo/.scalafix.conf")
rules += "AllowedShape"
AllowedShape.allowedTypes = ["scala/Predef.String", "scala/Int", ..., "cats/arrow", "com/example/myapp/core/SharedShape", "com/example/myapp/engine/arhitecture/"]
AllowedShape.disallowedConstructs = ["TermIf", "TermMatch", "TermWhile", "TermFor", "TermForYield", "TermTry", "TermThrow", "TermReturn", "LitNull", "DefnVar", "DeclVar", "Case", "TermPartialFunction", "TermCasesBlock"]
```

Those two keys and the `AllowedShape` section name are the rule's own config decoder (`AllowedShapeConfig`); the
schema, the symbol-prefix semantics of `allowedTypes` and the own-package-prefix convention are stated once in
`kit/arhitecture-shape/README.md` and not restated here. `baseAllowedTypes` (with the prefix appended) is what
`allowedTypes` receives; `.scalafix.conf` itself stays the project's ordinary ruleset and needs no `AllowedShape`
block.

The rendered lists are comma-separated **by construction** — `ScalafixValue.render` builds them with
`mkString("[", ", ", "]")` — which is why this path cannot hit the concatenation pitfall a hand-written list can
(`kit/arhitecture-shape/README.md`, "List entries are comma- or newline-separated": adjacent quoted strings become
one entry, and a denylist that matches nothing fails silently). Anything hand-written on the Mill side — the base
`.scalafix.conf`, or a module's own settings when they are written into a file rather than into
`extraRuleSettings` — needs the same commas, and `sh check.sh --config <file>` runs such a file through the kit's
own fixture pair before a module does.

## 5. SemanticDB (R3) — Mill supplies it, and the run proves it

`fix` hands the rule a classpath that includes `semanticDbData()` (mill-scalafix's own `fixAction`), so Mill compiles
the module with SemanticDB into `out/<module>/semanticDbData*.dest/**/META-INF/semanticdb/` — **no scalac option is
needed in the project's build**. That matters because the rule is a `SemanticRule`: with no SemanticDB its type half
is silent (`kit/arhitecture-shape/README.md`, "SemanticDB is not optional"). The check that it is actually on: a
disallowed *type* must be reported, not only a disallowed construct. A run that reports constructs but never types is
a run whose allowlist half proved nothing.

## 6. Run it

```sh
./mill <module>.fix --check          # one module: out/engine/arhitecture/...
./mill __.fix --check                # every module, recursively — skips the ones with no `fix` task (the rule module)
```

`--check` writes nothing and fails on findings: the rule's diagnostics are error severity by default (scalafix's
`Diagnostic`), and a lint error comes back as `ScalafixError.LinterError`, which the Mill plugin turns into a failed
task — so a violating module does not just print, it stops the build. (A rule whose diagnostics are explicitly
warning/info severity would *not* fail `--check`; skreeep2's `Layer.fixStrict` — `ScalafixArguments#evaluate()` over
the same tool classpath — is the pattern for that case. `AllowedShape` needs no such thing.)

Wire `fix --check` into the tasks your gate runs (`preCommit`/`prePush` in the build contract) so the check is not a
command a human has to remember.

## What this does not decide (R-11)

A green `fix --check` says the modules name allowlisted types and use no denylisted construct. It does not say the
split is right, that a component names a shape rather than spelling one, or that a contract is honest — and the rule
has a named blind spot (a disallowed type reached as a fully-qualified static term, never imported and never written
as a type) which `kit/arhitecture-shape/README.md` states in full. Do not read this recipe as closing either gap.

## The one rule that keeps this honest (R-10)

The policy is **per module**, and `baseAllowedTypes` is a starting point, not a shared exception list. When a module
needs an exception, it **removes the entry from its own list** — it never widens the base list other modules inherit,
and never suppresses a finding another way. A finding that cannot be fixed honestly is escalated, not silenced.

## How this recipe was checked

**Executed from this recipe's text alone.** A scratch project was assembled by extracting the code blocks out of this
file — the three `build.mill` fragments concatenated in order, `ScalafixExtra.mill`, `.scalafix.conf` — and copying
the two files the recipe says to copy (the helper, and the rule with its registration from
`kit/arhitecture-shape/`). Nothing was added by hand except the module's own source under check, which is the
consumer's code. Mill 1.1.8, mill-scalafix 0.6.2, Scala 3.8.4, scalafix 0.14.7; the module is the example's
`object engine { object arhitecture … }` with `packageRoot = "com/example/myapp/"` and a source under
`com.example.myapp.engine.arhitecture` that writes a disallowed type as a type, imports it, reaches a disallowed
object as a term, and uses an `if`.

That assembly is also what found the recipe's last installability defect: the head fragment had a `build.mill` label
comment above the `//|` lines, and Mill refused the build with
`build.mill:2:1 YAML header comments can only occur at the start of the file`. The block now starts with the header
(it is what made the difference between "the snippets work when typed into a build" and "the recipe works").

| Run (in the assembled project) | Result |
|---|---|
| `mill engine.arhitecture.fix --check`, violating source | exit **1**, `[error] engine.arhitecture.fix A Scalafix linter error was reported`, 4 diagnostics: 1 construct, 1 importee, 1 object-valued term, 1 plain type reference |
| the same command, source made clean | exit **0**, `SUCCESS`, 0 diagnostics |
| `mill __.fix --check`, violating source | exit **1**, the same 4 diagnostics — and the log shows `engine.arhitecture.*` tasks only, with no complaint about the rule module, so the recursive form skips the modules that have no `fix` task |
| generated config | `out/engine/arhitecture/scalafixConfig.dest/extra-rules.conf` — `include file("<repo>/.scalafix.conf")`, `rules += "AllowedShape"`, both keys, and `"com/example/myapp/engine/arhitecture/"` appended to `allowedTypes` |
| SemanticDB | `out/engine/arhitecture/semanticDbDataDetailed.dest/{classes,data}/META-INF/semanticdb/engine/arhitecture/src/Thing.scala.semanticdb` — produced with no scalac option in the build, and the plain-type-reference diagnostic is the proof it was used |
| the rendered-config block above (`...` expanded with the helper's remaining default stdlib entries, `include` pointed at the base file), **extracted from this file as committed** and run through `sh check.sh --config <block>` (R28) | exit **0**: violating **4** diagnostics [type references 1, importees 1, object-valued terms 1, constructs 1], clean **0** — `ScalafixValue.render`'s comma-separated arrays are list elements, not one concatenated string |
| the `.scalafix.conf` base block above, through the same mode (R28) | exit **1**, `mechanism 4 (construct denylist) did not run` — as its own comment says, this file is *included*, not the policy: it carries no `AllowedShape` keys, and the per-module policy is the generated config. Run it through `--config` and it fails the construct floor, which is the honest answer for a base ruleset |

The module's own `object Thing` produced no diagnostic, which is the own-package-prefix derivation from
`moduleSegments` doing its job — the prefix matched the module's real package without being spelled anywhere.

The two R28 rows are why the lists in the rendered block are comma-separated: a space-separated denylist
concatenates into one entry that matches nothing, and the construct half then fails **silently** — the type
diagnostics still arrive, so the run looks like an ordinary report. This path cannot hit it (the helper renders
arrays with commas), but a hand-written Mill-side policy can, which is what `check.sh --config` is for.

Two environment notes, so a reader can tell what was and was not the recipe's doing: the runs used the cached native
Mill launcher directly (`~/.cache/mill/download/1.1.8-native-mac-aarch64`) with `COURSIER_CACHE` and
`COURSIER_ARCHIVE_CACHE` pointed inside the work directory, because this sandbox cannot write the shared coursier
cache's `.structure.lock` (`mill`'s own launcher script fails with `StructureLockException` before reaching the
build). That is where the run happened, not part of the recipe — the task that ran, and the failure it reported, are
the recipe's own.

Also documentation-checked, from mill-scalafix 0.6.2's own sources: `scalafixToolClasspath`'s contract
(`ScalafixModule.scala` — "rules compiled in the same build … without a `publishLocal` round trip"), the classpath
`fix` builds (`compileClasspath() ++ localClasspath() ++ Seq(semanticDbData())`), and the `LinterError` → failed-task
mapping (`fixAction`).
