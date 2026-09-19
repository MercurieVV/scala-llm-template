# Recipe: sbt

sbt wiring for the kit's `AllowedShape` rule. The rule is vendored and **never published**, so it cannot ride
`scalafixDependencies` (that key resolves *published* artifacts from Maven/Ivy). sbt's own answer for an in-build rule
is the `ScalafixConfig` **Ivy configuration**: the rule compiles as part of the build, and a module that wants it
depends on the rule project in that configuration — scalafix's "Local rules" page documents exactly this shape. The
rule project's output classes then land on the tool classpath sbt-scalafix assembles.

- **Prerequisites:** sbt with [`sbt-scalafix`](https://scalacenter.github.io/scalafix/docs/users/installation.html) —
  written against, and executed with, 0.14.7 (sbt 1.11.6, Scala 3.8.4, JDK 21; see the bottom of this recipe).
- **What is frozen:** the rule name `AllowedShape`, the keys `allowedTypes` and `disallowedConstructs`, and the rule's
  own text. Everything below is wiring; none of it edits the rule file.

```
repo/
├── project/plugins.sbt                         # addSbtPlugin("ch.epfl.scala" % "sbt-scalafix" % "0.14.7")
├── build.sbt                                   # SemanticDB, the rule project, the module's config
├── scalafix-rules/                             # the vendored rule, compiled by the build, never published
│   └── src/main/
│       ├── scala/AllowedShape.scala            #   verbatim from kit/arhitecture-shape/
│       └── resources/META-INF/services/scalafix.v1.Rule
└── mymodule/
    ├── .scalafix.conf                          #   this module's own policy — both keys
    └── src/main/scala/…
```

## 1. The plugin, and SemanticDB (R3)

```scala
// project/plugins.sbt
addSbtPlugin("ch.epfl.scala" % "sbt-scalafix" % "0.14.7")
```

```scala
// build.sbt — SemanticDB is a precondition, not a detail: the rule is a SemanticRule, and with no SemanticDB its
// type half cannot run (kit/arhitecture-shape/README.md, "SemanticDB is not optional").
ThisBuild / scalaVersion    := "3.8.4"
ThisBuild / semanticdbEnabled := true
ThisBuild / semanticdbVersion := scalafixSemanticdb.revision
```

sbt-scalafix does not let that precondition fail silently: before running a semantic rule it checks the module's
resolved dependencies and scalac options (its `SemanticRuleValidator`), and if neither the `semanticdb-scalac` plugin
nor `-Xsemanticdb` is present the task **fails** with `The scalac compiler should produce semanticdb files to run
semantic rules like AllowedShape…` and the exact settings to add. So an unconfigured run is a red run, not a green
no-op — but do set the three lines above anyway; the failure message is a safety net, not a workflow.

## 2. The rule as its own project

```scala
// build.sbt

/** The vendored rule. `disablePlugins(ScalafixPlugin)`: the rule project is not itself linted. */
lazy val `scalafix-rules` = (project in file("scalafix-rules"))
  .disablePlugins(ScalafixPlugin)
  .settings(
    // `cross(CrossVersion.full)`, not `%%`: scalafix's rule artifacts are published per FULL Scala 3 version, so `%%`
    // asks for the non-existent `scalafix-rules_3` (a 404, measured). This resolves `scalafix-rules_3.8.4` — the
    // artifact the kit's own `check.sh` compiles the rule against.
    libraryDependencies += ("ch.epfl.scala" % "scalafix-rules" % "0.14.7").cross(CrossVersion.full)
  )
```

The rule's source is `kit/arhitecture-shape/AllowedShape.scala` copied verbatim to
`scalafix-rules/src/main/scala/AllowedShape.scala`, and the kit's `META-INF/services/scalafix.v1.Rule` to
`scalafix-rules/src/main/resources/META-INF/services/scalafix.v1.Rule` — resources are copied into the project's
classes, which is how `--rules AllowedShape` resolves the class. Compile the rule against the scalafix version whose
CLI will load it — `scalafix-rules` 0.14.7 with sbt-scalafix 0.14.7, the pair above. The rule's runtime imports
(`scalafix.v1.*`, `metaconfig.*`, `scala.meta.*`) come from the CLI's parent classloader; that is why
`kit/arhitecture-shape/check.sh` puts *only* the rule's classes plus the registration on the tool classpath.

If your build has no sub-projects, scalafix's documentation gives the same mechanism for a single project: the rule
lives in `src/scalafix/scala/AllowedShape.scala` with its registration in `src/scalafix/resources/`, and the project
buys the dependency in the `ScalafixConfig` configuration. The sub-project form above is the one that keeps the rule
shared and unpublishable, which is the kit's layout.

## 3. A module opts in, and carries its own policy

```scala
lazy val mymodule = (project in file("mymodule"))
  .dependsOn(`scalafix-rules` % ScalafixConfig)          // the rule rides the tool classpath, not the app classpath
  .settings(
    scalafixConfig := Some(baseDirectory.value / ".scalafix.conf")
  )
```

`mymodule/.scalafix.conf` — this module's own policy, both keys, under the rule's own name:

```hocon
# mymodule/.scalafix.conf
rules = [
  AllowedShape        # and whatever else this module runs (OrganizeImports, DisableSyntax, …)
]

AllowedShape {
  allowedTypes = [
    "scala/Predef.String"
    "scala/Int"
    "scala/Boolean"
    "scala/Unit"
    "scala/Any"
    "cats/arrow"                              # a prefix: everything under it is allowed
    "com/example/myapp/core/SharedShape"
    "com/example/myapp/mymodule/"             # this module's own package prefix
  ]
  disallowedConstructs = [
    "TermIf" "TermMatch" "TermWhile" "TermFor" "TermForYield" "TermTry" "TermThrow"
    "TermReturn" "LitNull" "DefnVar" "DeclVar" "Case" "TermPartialFunction" "TermCasesBlock"
  ]
}
```

Unlike the CLI form, the `rules` list **is** how this run selects rules: sbt-scalafix hands the config file to the CLI,
and `scalafixAll` runs over the configurations where scalafix is enabled (Compile and Test by default). `AllowedShape`
must therefore appear in `rules` — naming only the section leaves the module unlinted. The two keys and the
`AllowedShape` section name are the rule's own config decoder; `kit/arhitecture-shape/README.md` states the schema,
the symbol-prefix semantics of `allowedTypes` and the own-package-prefix convention once — this recipe does not
restate them. Several modules sharing a base ruleset can `include file("…")` an absolute path exactly as the Mill
recipe's generated config does; the module's own `AllowedShape` block stays in the module's own file either way.

`scalafixConfig` defaults to `None`, which lets the CLI infer `<build root>/.scalafix.conf` — fine for a project-wide
ruleset, but it is not per module, so a shaped module states its own file as above.

If your rules *are* published (not this kit's rule), the other key is `scalafixDependencies` — a list of published
`ModuleID`s for the tool classpath:

```scala
ThisBuild / scalafixDependencies += "com.example" %% "my-published-rules" % "1.0.0"
```

## 4. Run it

```sh
sbt "scalafixAll --check"                 # every project/config where scalafix is enabled
sbt "mymodule/scalafix --check"           # one project
sbt "mymodule/Compile/scalafix --check"   # one project and configuration
```

`--check` writes nothing and fails on findings: `AllowedShape`'s diagnostics are error severity by default (scalafix's
`Diagnostic`), the CLI reports them as a linter error, and sbt-scalafix surfaces that as a failed task — the build
stops rather than printing a warning. (A rule whose diagnostics are explicitly warning/info severity would not fail
`--check`.) Wire the command into the tasks your gate runs (`preCommit`/`prePush` in the build contract) so nobody has
to remember it.

## What this does not decide (R-11)

A green `scalafixAll --check` says the modules name allowlisted types and use no denylisted construct. It does not say
the split is right, that a component names a shape rather than spelling one, or that a contract is honest — and the
rule has a named blind spot (a disallowed type reached as a fully-qualified static term, never imported and never
written as a type) that `kit/arhitecture-shape/README.md` states in full.

## The one rule that keeps this honest (R-10)

The policy is **per module**: `scalafixConfig` points at the module's own file, and that file's `AllowedShape` block
is that module's list. When a module needs an exception, it **removes the entry from its own list** — it never widens
a config another module uses, and never suppresses a finding another way. A finding that cannot be fixed honestly is
escalated, not silenced.

## How this recipe was checked

**Executed**, end to end, on a scratch sbt project built from this recipe (sbt 1.11.6, sbt-scalafix 0.14.7, Scala
3.8.4, scalafix 0.14.7, JDK 21): the rule at `scalafix-rules/src/main/scala/AllowedShape.scala` with its registration
under `scalafix-rules/src/main/resources/`, `ThisBuild / semanticdbEnabled := true`, and one module —
`.dependsOn(\`scalafix-rules\` % ScalafixConfig)` with `scalafixConfig := Some(baseDirectory.value / ".scalafix.conf")`
— over a source that writes a disallowed type as a type, imports it, reaches a disallowed object as a term, and uses
an `if`.

| Run | Result |
|---|---|
| `sbt "scalafixAll --check"`, violating source | exit **1**, `[error] (mymodule / scalafixAll) scalafix.sbt.ScalafixFailed: LinterError`, 4 diagnostics: 1 construct, 1 importee, 1 object-valued term, 1 plain type reference |
| the same command, source made clean | exit **0**, `[success] Total time: 3 s` |
| the rule's own `object Thing` | no diagnostic — the module's own package prefix in `allowedTypes` covers it |

The plain-type-reference diagnostic is the proof that SemanticDB was in play (`semanticdbEnabled := true` on Scala
3.8.4), so the allowlist half really ran.

That first run also caught a defect in this recipe, which is why the dependency above is spelled
`("ch.epfl.scala" % "scalafix-rules" % "0.14.7").cross(CrossVersion.full)` and not `%%`: the `%%` form resolves
`scalafix-rules_3`, which **is not published** — sbt failed with `Error downloading
ch.epfl.scala:scalafix-rules_3:0.14.7 … Not found`, and a direct check of Maven Central returns **404** for
`scalafix-rules_3/0.14.7/scalafix-rules_3-0.14.7.pom` and **200** for the `_3.8.4` form (as it does for
`scalafix-core_3` vs `scalafix-core_2.13`). Rule artifacts are published per full Scala 3 version.

Environment note: the runs redirected sbt's boot/global/Ivy directories and the coursier cache into the work
directory (`-Dsbt.boot.directory`, `-Dsbt.global.base`, `-Dsbt.ivy.home`, `COURSIER_CACHE`), because this sandbox
cannot write outside its workspace. That is where the run happened, not part of the recipe.

Documentation-checked, from the tools' own sources, for the parts a single run cannot show:

| Claim | Source |
|---|---|
| The tool classpath is `(ScalafixConfig / products) ++ (ScalafixConfig / internalDependencyClasspath)` plus `scalafixDependencies` | sbt-scalafix 0.14.7 sources, `scalafix/sbt/ScalafixPlugin.scala` (`scalafixTask`: `projectDepsInternal` / `projectDepsExternal`, and `scalafixArgsFromShell`'s `Arg.ToolClasspath`) |
| `scalafixDependencies` is for published artifacts; an in-build rule uses the `ScalafixConfig` configuration | scalafix docs, [Local rules](https://scalacenter.github.io/scalafix/docs/developers/local-rules.html) (single-project and separate-sub-project forms, `dependsOn(rules % ScalafixConfig)`) |
| A semantic rule without SemanticDB fails with the `SemanticdbNotFound` message | sbt-scalafix 0.14.7 sources, `scalafix/internal/sbt/SemanticRuleValidator.scala` (`hasSemanticdb` check plus the settings it prints) |
| `scalafixConfig` defaults to `None` (CLI infers the build root's `.scalafix.conf`) | sbt-scalafix 0.14.7 sources, `ScalafixPlugin.scala` default settings |
| `scalafixAll` covers Compile and Test by default; `--check` is passed through to the CLI | sbt-scalafix 0.14.7 sources, `autoImport` (`scalafixAll`, `scalafixConfigSettings`) |
| Error-severity lint diagnostics fail the run | scalafix 0.14.7 sources: `Diagnostic`'s default severity is `LintSeverity.Error` (`scalafix/lint/Diagnostic.scala`), and `MainOps.adjustExitCode` merges `LinterError` when the callback saw one — and the run above, which failed with exactly that |

The rule name, the two keys and the classpath shape are the same ones the kit's own `check.sh` and this kit's Mill
recipe exercise for real.
