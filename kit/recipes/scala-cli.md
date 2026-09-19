# Recipe: scala-cli

scala-cli wiring for the kit's `AllowedShape` rule. scala-cli has no build to hang a rule module on, and it resolves
scalafix rules **only** from `//> using scalafixDependency` directives — published artifacts. The rule is deliberately
unpublished (vendored, not published), so this recipe's runnable form is the **tool-classpath CLI form**: compile the
vendored rule, stage its registration, compile the sources under check with SemanticDB, and run the scalafix CLI on
the result. That is the same invocation `kit/arhitecture-shape/check.sh` proves against the kit's own fixtures; a
project runs its own copy of it (see R16 at the bottom).

- **Prerequisites:** `scala-cli` (compiler driver) and `cs` (coursier, to launch the CLI). No build file, no plugin,
  nothing added to the project's `project.scala`.
- **What is frozen:** the rule name `AllowedShape`, the keys `allowedTypes` and `disallowedConstructs`, and the rule's
  own text. Everything below is wiring; none of it edits the rule file.

```
repo/
├── .kit/
│   └── arhitecture-shape/                  # the kit's directory, copied in as-is
│       ├── AllowedShape.scala              #   the rule, verbatim
│       ├── META-INF/services/scalafix.v1.Rule  #   the registration (one line, the FQCN)
│       └── README.md, check.sh, fixtures/… #   the kit's own fixture check — not a project lint runner (R16)
├── shape-policy/
│   └── engine-arhitecture.conf             # ← you write one of these per shaped directory: its own policy
├── allowed-shape.sh                        # the runner below
└── src/…                                   # the sources under check
```

The kit's directory is dot-prefixed on purpose: scala-cli skips dot-directories, so the project's own
`scala-cli compile .` never picks up a rule that is compiled against scalafix's API rather than the project's
(see "Keeping the rule out of the project's own compile" below).

Only `AllowedShape.scala` and the registration come from the kit; the policy files are the project's own, and the
runner takes them as arguments — which is what makes the policy per directory.

## Why not `scala-cli --power scalafix .`

Measured with scala-cli 1.15.0 in this kit's environment (see "How this recipe was checked"):

- `scala-cli fix --help-full` (**`fix`** is the current name; `scalafix` is its alias) has **no option for rules or a
  tool classpath** — nothing in the full help mentions `scalafix`.
- A `.scalafix.conf` that names `AllowedShape` and no `scalafixDependency` directive produces
  `Running scalafix rules... No rules requested to run` and **exit 0**: the config's rule list is not what scala-cli
  selects rules from, so the project gets a green run that proved nothing.
- Naming the rule as a directive (`//> using scalafixDependency io.github.mercurievv::arhitecture-shape:0.0.0`) makes
  scala-cli try to *download* it (`Downloading …/arhitecture-shape_2.13-0.0.0.pom`), and when the resolution fails it
  still **exits 0** — a failure that looks like a pass, the exact defect R-8 names.

A silent pass is worse than no recipe, so this recipe does not use that form. If a project ever publishes its rule,
`//> using scalafixDependency <org>::<name>:<version>` plus `scala-cli --power fix .` becomes the short form — until
then it is not a check.

## The runner

Save this as `allowed-shape.sh` (POSIX `sh`, `set -eu`; `--server=false` keeps scala-cli non-interactive — this
sandbox cannot start Bloop, and a gate should not need a compilation server either). It takes the directory to check
and that directory's own config, and it **ends on the CLI's own exit status** rather than counting diagnostics: under
`set -eu` a failing CLI fails the script with its code (64 for a finding, 8 for missing SemanticDB, …), and a failed
run leaves no diagnostics at all — so counting alone would read a failure as "no findings".

```sh
#!/bin/sh
# allowed-shape.sh — run the vendored AllowedShape rule over one shaped directory.
# Usage: sh allowed-shape.sh <sources-dir> <config-file>
set -eu

SRC=${1:?usage: allowed-shape.sh <sources-dir> <config-file>}
CONF=${2:?usage: allowed-shape.sh <sources-dir> <config-file>}
RULE_DIR=.kit/arhitecture-shape                               # the kit's directory, copied in as-is (dot-prefixed: the project's own compile must skip it)
SCALA=3.8.4
SCALAFIX=0.14.7
WORK=.allowed-shape                                          # by-products, safe to delete

# 1. compile the rule itself, against the scalafix rules artifact of the same version
scala-cli compile "$RULE_DIR/AllowedShape.scala" \
  --server=false --scala "$SCALA" \
  --dep "ch.epfl.scala:scalafix-rules_${SCALA}:${SCALAFIX}" \
  --workspace "$WORK/ws-rule" -d "$WORK/rule-classes"

# 2. tool classpath = the rule's classes + its registration, and nothing else. The CLI's parent classloader already
#    carries scalafix-core/metaconfig/scalameta at this version, so the scalafix-rules jar is NOT re-added.
rm -rf "$WORK/tool-classes" && mkdir -p "$WORK/tool-classes"
cp -R "$WORK/rule-classes/." "$WORK/tool-classes/"
cp -R "$RULE_DIR/META-INF" "$WORK/tool-classes/"

# 3. compile the sources under check WITH SemanticDB — the rule is a SemanticRule, and without this its type half is
#    silent. --semanticdb-sourceroot must be the directory the stored paths are relative to.
scala-cli compile "$SRC" \
  --server=false --scala "$SCALA" \
  --semanticdb --semanticdb-sourceroot "$PWD" \
  --workspace "$WORK/ws-src" -d "$WORK/classes"

# 4. run the rule. The CLI's own exit codes — scalafix's `ExitStatus` has ten base codes and ORs them together when
#    several apply: 0 Ok, 1 UnexpectedError, 2 ParseError, 4 CommandLineError, 8 MissingSemanticdbError,
#    16 StaleSemanticdbError, 32 TestError (--check found a rewrite to apply), 64 LinterError (diagnostics
#    reported), 128 NoFilesError, 256 NoRulesError. 64 and 8 are measured below; `check.sh`'s own 0/1/2 mean
#    something different — do not read one table as the other.
cs launch "ch.epfl.scala:scalafix-cli_${SCALA}:${SCALAFIX}" --main-class scalafix.cli.Cli -- \
  --tool-classpath "$WORK/tool-classes" \
  --rules AllowedShape \
  --config "$CONF" \
  --classpath "$WORK/classes" \
  --sourceroot "$PWD" \
  --check "$SRC"
```

```sh
sh allowed-shape.sh src/engine/arhitecture shape-policy/engine-arhitecture.conf
```

## Keeping the rule out of the project's own compile

The rule is compiled against scalafix's API, not the project's, so it must not sit in the tree the project compiles.
For a project whose sources live at the repo root (this kit's own template is one), measured here:

- the runner below compiles explicit directories, which is the straightforward answer — pass the shaped directory, and
  the rule directory is never in that list;
- `--exclude arhitecture-shape` does **not** do it: the rule was still compiled and the run failed with 5 errors;
- scala-cli skips dot-directories: with the rule under `.kit/`, `scala-cli compile .` compiled the project's sources
  and left the rule alone (exit 0) — which is why the tree above installs the kit at `.kit/arhitecture-shape/` and
  the runner's `RULE_DIR` names that path.

## The config, both keys

Each shaped directory gets its own config, written by you, at whatever path you pass to the runner — that is where its
policy lives, never in the rule file:

```hocon
# shape-policy/engine-arhitecture.conf
AllowedShape {
  allowedTypes = [
    "scala/Predef.String",
    "scala/Int",
    "scala/Boolean",
    "scala/Unit",
    "scala/Any",
    "cats/arrow",                       # a prefix: everything under it is allowed
    "com/example/myapp/core/SharedShape",
    "com/example/myapp/engine/arhitecture/"   # this directory's own package prefix
  ]
  disallowedConstructs = [
    "TermIf", "TermMatch", "TermWhile", "TermFor", "TermForYield", "TermTry", "TermThrow",
    "TermReturn", "LitNull", "DefnVar", "DeclVar", "Case", "TermPartialFunction", "TermCasesBlock"
  ]
}
```

The entries are comma-separated on purpose: HOCON concatenates adjacent quoted values, so
`["TermIf" "TermMatch"]` is one entry that matches nothing — and a denylist that matches nothing fails
**silently** (the type half still reports). `kit/arhitecture-shape/README.md`, "List entries are comma- or
newline-separated", states the full pitfall; from the project root, `sh .kit/arhitecture-shape/check.sh --config
shape-policy/engine-arhitecture.conf` runs this file through the kit's own fixture pair before the directory does
(this recipe is the one that vendors the script with the kit's directory; in a kit checkout the same script is at
`kit/arhitecture-shape/check.sh`).

The `AllowedShape` section name, the two keys, the symbol-prefix semantics of `allowedTypes` and the
own-package-prefix convention are the rule's own config decoder — `kit/arhitecture-shape/README.md` states the schema
once; this recipe does not restate it. `rules = [...]` is deliberately absent: rules are named on the CLI's
`--rules`, and scala-cli's own rule selection (above) is not used.

## SemanticDB (R3) — the precondition, not a detail

Step 3's `--semanticdb --semanticdb-sourceroot <dir>` is what makes the allowlist half of the rule run at all. Both
failure modes are silent-looking and both are stated in `kit/arhitecture-shape/README.md` ("SemanticDB is not
optional"); measured here as well: without it the CLI answers `SemanticDB not found` and exits **8** — a run that
reported nothing, not a run that found nothing. A bare `-Xsemanticdb` is not the same flag: it writes the file beside
the source, which the CLI cannot see. And a *first* run against a fresh directory must show type diagnostics for a
disallowed type; if it only ever reports constructs, the allowlist half proved nothing.

## What this does not decide (R-11)

A green run says the checked directories name allowlisted types and use no denylisted construct. It does not say the
split is right, that a component names a shape rather than spelling one, or that a contract is honest — and the rule
has a named blind spot (a disallowed type reached as a fully-qualified static term, never imported and never written
as a type) that `kit/arhitecture-shape/README.md` states in full.

## The one rule that keeps this honest (R-10)

The policy is **per directory**: `allowed-shape.sh` takes the config as an argument, and each config is that
directory's own. When a directory needs an exception, it **removes the entry from its own list** — it never widens a
config another directory uses, and never suppresses a finding another way. A finding that cannot be fixed honestly is
escalated, not silenced.

## R16: this is not `check.sh`

`check.sh` is the kit's own fixture check: its `EXPECT_*` constants and its default allowlist are deliberately
fixture-specific, and pointing it at a project makes it fail by design. The runner above is the project-facing
mechanism; copy the commands, not the expectations.

## How this recipe was checked

**Executed** in a scratch directory (scala-cli 1.15.0, scalafix 0.14.7, Scala 3.8.4), against a copy of the kit's own
`arhitecture-shape/` directory and its committed fixture pair:

| Run | Result |
|---|---|
| `sh allowed-shape.sh src shape-policy/engine-arhitecture.conf` — the runner above, extracted from this file and run as it stands | exit **64**, 4 diagnostics: type references 1, importees 1, object-valued terms 1, constructs 1 |
| the same runner on a clean source directory | exit **0**, 0 diagnostics |
| the runner at this file's tree path, `.kit/arhitecture-shape/` (re-run when the tree and `RULE_DIR` moved out of the compiled tree — R25) | exit **64** with the same 4 diagnostics; clean directory exit **0** |
| rule compile (step 1) | exit 0; `.allowed-shape/rule-classes/io/github/mercurievv/arhitecture/scalafix/AllowedShape.class` |
| the same sources compiled without `--semanticdb` | exit **8**, `error: SemanticDB not found: src/example/Example.scala` |
| `scala-cli --power fix src` with `AllowedShape` in `.scalafix.conf` | exit **0**, `Running scalafix rules... No rules requested to run` |
| `//> using scalafixDependency io.github.mercurievv::arhitecture-shape:0.0.0` | download attempted, failed, exit **0** |
| the `shape-policy/engine-arhitecture.conf` block above, **extracted from this file as committed** and run through `sh check.sh --config <block>` from the kit directory (R28) | exit **0**: violating **4** diagnostics [type references 1, importees 1, object-valued terms 1, constructs 1], clean **0** — the committed commas are list separators, so all fourteen construct names are entries |

The 4-and-0 counts are the same numbers `kit/arhitecture-shape/check.sh` asserts for the committed pair (its README,
"What this check measures"), reproduced here through this recipe's own commands.

The last row is the R28 addition, and it is the reason the lists above are comma-separated: a space-separated
denylist concatenates into one entry, matches nothing, and leaves the construct half silently unchecked. The same
block in that spelling was measured through the same mode and **fails** — exit 1, `the violating fixture produced
no disallowedConstruct diagnostic: mechanism 4 (construct denylist) did not run` — so the block committed here is
the one that was run, and a future edit that breaks its spelling turns this row red instead of quiet.
