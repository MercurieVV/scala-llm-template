# Applying the kit to a project

The procedure a human or an agent follows to bring a project nobody prepared under the kit: the `AllowedShape` rule
and its build wiring (L2), and the five process skills with the `AGENTS.md` digest (L3/L5). The authority is the
design's §*The procedure: applying the kit to a project*; this document states that procedure against the artifacts
as they are — the installer (`Setup.scala`'s `kit` feature), the recipes in `kit/recipes/`, the skills in
`kit/skills/`, and the rule's own README — and says where each step's output and stop condition go.

Not in this document: the `R-1 … R-14` rule text (the `scala-coding-guidelines` wiki,
`wiki/reengineering/reengineering-contract.md`, which the digest points at). The harness (L4 — the gate runner,
`gate.sh`, hooks, the semantic guard, frozen paths) is installed at step 2b and documented in `kit/harness/README.md`.
This document uses the gate's **contract** — the three task names `preCommit`, `prePush`, `checkFormat`, a coverage
map and the source roots — and holds for a project without that harness too (sbt, scala-cli).

## Before step 1

- **A local checkout of `scala-llm-template`.** The `kit` feature reads the rule, the recipes' code blocks, the
  enforcement README and the five skills from the checkout's `kit/` directory at run time, so the remote one-liner
  that fetches `Setup.scala` alone cannot install them — it fails with that reason. Every command below runs
  from that checkout. And the run's exit status is not the verdict: the pre-existing agent-mode machinery ends
  every run with `=== Setup Completed Successfully! ===` and exit 0 even when a step reported `failed`, so read
  the JSON on stdout — each step's own `status` — rather than only the exit code.
- **The project's build tool** — Mill, sbt or scala-cli: the answer that selects the recipe.
- **A clean working tree** — step 2 is one commit, and step 3's baseline is measured before anything else moves.

## 1. Read the ground

Collect, from the project's build and sources:

- **the build tool**, and how its build declares tasks;
- **the module map and the source roots** — every module, where its sources live, what it depends on;
- **which modules carry composition** — the modules whose code composes work (arrows, pipelines, contracts, the
  things other modules consume) rather than the modules that are only data or entry points. These are the modules
  step 6's exit condition is about;
- **where an abstract level could sit in each of them** — what the module's callers actually need to name, and which
  concrete types are implementation detail below that line;
- **the own-package prefix** each shaped module's allowlist will need (`com/example/myapp/<module>/`), derived from
  the module's real package, not from the build's module path.

Read sources through the project's symbol-level tooling, not text search (R-14).

**Output — two artifacts, both written down:**

1. **the proposed module list**: every module with **one sentence of purpose**. If a purpose needs two sentences, the
   module is doing two jobs, and the split is part of the work rather than a consequence of it;
2. **the contract file**: the project's declaration of the three task names (`preCommit`, `prePush`, `checkFormat`),
   the coverage map (which module is formatted, linted, compiled, tested) and the source roots. The approved module
   list and the strictness dial — which modules this pass may touch — live with it (R-13).

**Stop condition: a human approves the module list before anything else starts.** No install, no build edit, no
"while I am here". The list is the pass's declared scope, and a scope read back off a diff later is what R-13
forbids; until the approval, step 1's output is a proposal.

## 2. Install the project's kit state

One command, from the checkout, naming the target project's directory:

```bash
scala-cli run Setup.scala --server=false -- --agent --answers '{"kit":"yes","build-tool":"mill"}' <target-dir>
```

`build-tool` takes `mill`, `sbt` or `scala-cli` and selects the recipe; `--server=false` keeps the run off a Bloop
daemon; an interactive run is the same script without `--agent`, answering the prompts (`kit` → yes). `--agent`
requires a complete answer set: answers not passed inline are read from the target's `.agents/answers.json`, and if a
question is still unanswered the run writes that file, exits 2 and lists what it needs — no step runs.

What the install writes — the **shared** half only:

| Tool | Written |
|---|---|
| **Mill** | `scalafixRules/src/AllowedShape.scala` and `scalafixRules/resources/META-INF/services/scalafix.v1.Rule`; `buildKit/package.mill` and `buildKit/ArchitectureShapeModule.mill`; `ScalafixExtra.mill`; `build.mill` (the rule module, `BuildPaths`, the tool-classpath trait, the per-module mix-in **commented**); `.scalafix.conf` when the project has none |
| **sbt** | `scalafix-rules/src/main/scala/AllowedShape.scala` and `scalafix-rules/src/main/resources/META-INF/services/scalafix.v1.Rule`; the plugin line in `project/plugins.sbt`; a marked block in `build.sbt` (SemanticDB, the rule project, the per-module opt-in **commented**) |
| **scala-cli** | `.kit/arhitecture-shape/` — the rule, its registration, the enforcement README, `check.sh` and its fixtures — and `allowed-shape.sh` |

Then, for every tool: `.kit/arhitecture-shape/README.md` (the enforcement README the digest points at), the five
skills byte-for-byte under `.dsh/skills/<name>/SKILL.md`, and the digest planted between
`<!-- reengineering-kit:begin -->` and `<!-- reengineering-kit:end -->` in `AGENTS.md` (created when the project has
none) and, where they exist, `.agents/AGENTS.md` and `scala-rules.md`.

Two things the design's step 2 names belong to the harness (L4), not to the kit files above: the **harness
pointer** (`.dsh/hooks.json` / `.dsh/cc-settings.json`, every command `sh "$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh"
<sub>`) and **frozen paths** (`.dsh/frozen-paths`). For a Mill project the same run's `install-harness` step seeds
both — see step 2b. Beyond the seeded entries (`.dsh/engine/**` and the harness's own state files), add no
source path unless the human is mid-flight, which is the only thing a source freeze is for. For sbt and scala-cli the harness is not installed (the step
is skipped by name): the tasks you wire in step 4 are the gate's contract, and step 3's baseline is what they print.

**Output: one commit for the install; no behaviour change.** The installer stages what it wrote (its last step is
`git add .`). On a project already committed and clean, the staged set is the kit's files and you commit exactly
those; on a fresh project the same run also writes the template's own state, so commit that as its own commit (or as
part of this one) before any reshape — never mix an install into a reshape's commit. Nothing the install writes
changes compilation or behaviour until a module opts in at step 4. For a Mill target generated by this template, note
which build file Mill 1.x actually reads: the installer writes `build.mill` when the project has none and says so on
stderr — Mill ignores `build.sc`, so move the project's modules into `build.mill` (or a sibling `.mill` file) before
step 3.

**Stop condition:** the install is committed, its stat lists the kit's paths (`git show --stat`), and the diff
contains no reshape of any module. A failed install says so and names the reason — and the run's exit code is not
that answer, because agent mode still ends with `=== Setup Completed Successfully! ===` and exit 0 when a step
failed: read the JSON's per-step `status`. Re-running is safe — the install is idempotent, rewriting the same bytes
(the marked blocks are replaced, never appended). One caveat, because the kit is vendored: a file the kit wrote is
yours to tune, and a re-install that finds it changed does **not** overwrite it — it writes the kit's own version
beside it as `<file>.kit-new` and says so on stderr, leaving the merge to you.

## 2b. Install the harness (Mill projects)

The harness engine is vendored into the project as `.dsh/engine/` by `kit/harness/install.sh`; its README,
`kit/harness/README.md` (vendored as `.dsh/engine/README.md`), is the full reference — layout, `STAMP`, drift, the
contract keys, the Mill interface, every note the gate prints, its blind spots. Step 2's run already calls it as
its `install-harness` step when `build-tool` is `mill` (any other build tool is skipped by name: the engine's checks
are Mill tasks). Run it by hand, from the scala-llm-template checkout, to install on its own or to update the
engine later:

```bash
sh kit/harness/install.sh <target-dir>
```

- **The target must already be a git repository.** Setup's own `git init` is its last step, after
  `install-harness`, so on a brand-new target directory that step reports
  `failed: install.sh exited 2: … not a git repository`. Remedy: `git init <target-dir>` and re-run.
- It replaces `.dsh/engine/` wholesale, writes `.dsh/engine/STAMP`, and seeds `.dsh/contract`, `frozen-paths`,
  `hooks.json`, `cc-settings.json`, `policy/*.tsv` and `instructions/{local,scalac-kinds}.tsv` **only where
  absent** — one `seeded` / `kept` / `replaced` line per file. Exit codes are in the README.
- **The Claude Code wiring is the human's step.** `.claude/settings.json` is copied from `.dsh/cc-settings.json`
  by the human (merging anything already there); no installer and no agent writes it.
- **Add recipe §7's root tasks.** Copy `kit/recipes/mill/Gate.mill` to `buildKit/Gate.mill`, mix `GateLayer`
  into every module scalafix checks, and add the root tasks from `kit/recipes/mill.md` §7 (`preCommit`,
  `prePush`, `moduleMap`, `scalaSemanticWriteClasspath`) over the project's own module lists. The engine calls
  those task names; without them its checks fail by name.

**Stop condition:** `sh .dsh/engine/check-harness.sh --project .` reports
`ok   vendored engine matches its STAMP`, every other FAIL it prints is written into step 3's baseline with its
reason (a machine prerequisite such as a missing ScalaSemantic launcher is a FAIL there, not a pass), and the
vendored engine is committed on its own as `dsh: vendor engine <sha7>`.

## 3. Baseline the gate

Run the project's gate as it stands and **record what it says, red or noisy** — the exact command, its exit status
and its raw output, before any reshape. That baseline is what later diffs are measured against: a module that was
already red is work in progress, not a regression this pass caused; a finding that was already there is not this
pass's doing.

- The gate is the project's `preCommit` / `prePush` tasks — Mill tasks, sbt tasks or aliases, or the scala-cli
  runner wired into the project's own scripts. The per-module half from step 4 is what puts the shape check inside
  them, so on the first pass the baseline may be the project's existing checks plus a shape check that reports
  nothing yet.
- Where the harness (L4) is installed it runs the declared tasks only and refuses coverage the map does not grant;
  where it is not, the commands themselves are the gate and their output is still the receipt.
- **No suppressions (R-10).** The baseline is not a list to silence: do not widen an allowlist, lower a severity, or
  comment out a failing check to make it green. If no baseline can be produced at all, write that down with its
  reason — an unbaselined gate has no `before`, so every later diff is an assertion.

**Output: the baseline receipt** — command, exit status, raw output — stored where the work is recorded (the
module's spec, the migration notes, the pull request), not in a private scratch file.

**Stop condition:** the baseline exists, quoted verbatim, and it was taken *before* the first module moved.

## 4. Reshape one module

One module per pass (R-13). The four skills, in this order — each is a checkpoint, and the order is the part that
does not bend:

1. **`shaping-a-module` (R-2, R-4) — decide the split before types move.** Survey the module symbol-level (R-14),
   name its purpose in one sentence, then decide which half is the abstract level (arrows, abstract type members,
   the laws) and which is the concrete instantiation. Extrude outward and downward, never upward; a shape a
   signature needs is named once and reused rather than spelled at the use site (R-4). Extend the module's own
   allowlist deliberately, by what the contract needs and nothing else. *Output:* the split, the allowlist entries,
   the module's purpose still one sentence.
2. **`reengineering-module` (R-13) — narrow the pass, and name what happens to dependants.** Fill in the three roles
   from step 1's approved list: the fixed modules (already reengineered — source of truth, read-only), the one
   module this pass changes, and its dependants (not yet reshaped — excluded from this pass's compilation and tests,
   disabled in the build, never deleted). Fix in order: main compile, test compile, test run. *Output:* the roles
   written down, the dependants' exclusion recorded (R-12), the module compiling with its tests *run*.
3. **`reshaping-module-by-linters` (R-10, R-11) — fix code, never config.** Every finding gets a code fix. No
   `@SuppressWarnings`, no `// scalafix:ok`, no exclusion, no allowlist widening, no threshold bump. A finding that
   cannot be fixed honestly is escalated (see *The escalation rule* below), not silenced. *Output:* findings fixed
   in source, or an escalation carrying its three facts.
4. **`verify-before-done` (R-8, R-9) — earn "done".** The gate's own output, quoted, with the tests *run* rather
   than merely compiled, plus an independent lane (`verification-lane`) that judges the diff against the
   `R-1 … R-14` IDs and returns a verdict per ID, citing symbols rather than praise. The lane gets the diff, the
   rule list, the contract file and the target list — never your summary — and it fixes nothing. *Output:* the
   receipt and the lane's verdicts.

**Stop condition:** all four outputs exist for this one module — the split and its allowlist entries, the three
roles with the module compiling and its tests *run*, every lint finding fixed in source (or an escalation carrying
its three facts), and the receipt plus verdicts — the diff touches no module outside step 1's approved list, and
nothing was suppressed to get there. A module whose four outputs are not all in hand is still in step 4, whatever
the gate says.

The module's own half of the wiring is written here, not by the installer — see *The per-module half the installer
leaves* below for where each tool keeps it.

## 5. Record

The record travels with the code (R-12), in the same pass:

- the project's **contract file and dial** updated as the shape moves — coverage map, task names, target list,
  strictness setting;
- **stale claims corrected** — a document describing a tree that no longer exists is corrected in this commit, not
  left for later;
- **divergences written down as rulings** — what was expected, what was done instead, and the cost of each option;
  an unreconciled open question is a ruling too;
- step 3's **baseline** and step 4's **receipt** kept where a reader can find them.

**One commit per module.** The commit carries the reshape, the wiring half that activates it, and the record.
Ledgers, progress files and task lists are convenience; they are never the record.

**Stop condition:** the record matches the code in the commit — a reader who opens only the commit can reconstruct
what changed in the contract, and why.

## 6. Repeat to the exit condition

Back to step 4 for the next module on the approved list. The exit condition has three parts, all three checked
against the tree rather than against the plan:

1. **every composition-carrying module has the two-level split with its own allowlist** — its own policy, its own
   list, never a shared exception list;
2. **the gate is green** — its own output, over the whole project, with the tests run (R-8);
3. **every module has its one-sentence purpose** — step 1's list, now true of the tree.

Step 5's record is what makes "every module" checkable: a module nobody reshaped appears on the list as *not yet
reshaped*, with its reason, rather than being absent from it.

**Before declaring that exit condition met, read the next section.** A green gate is the machine's half.

## The boundary checkpoint (R-11): a green gate is not a correct split

This is where a pass is most tempted to stop: the gate is green, the tests run, the check prints nothing. R-11 is
the rule about what that does and does not settle.

| Machine-decidable — L2's business | Judgement — L1/L3/L5's business |
|---|---|
| a concrete type outside the allowlist | is this the right split |
| an imperative construct | does this component *name* a shape rather than spell one |
| unformatted code | is this contract honest |
| a red compile | is this divergence a fix or a design change |
| a lint finding | — |
| a test that does not run | — |

A green run says the module names allowlisted types and uses no denylisted construct. It does not say the split is
right, that a component named a shape rather than spelling one, or that a contract is honest — those go to the
verification lane (R-9) and to the human who approved the list. Never let the machine's half stand in for the
judgement half.

The rule's own edge is written down rather than left to be discovered: a disallowed type reached as a
fully-qualified static term, never imported and never written as a type, produces no diagnostic — the named blind
spot in the enforcement README (`kit/arhitecture-shape/README.md` in the checkout,
`.kit/arhitecture-shape/README.md` in an installed project). Where that matters, the rule cannot be the only thing
standing between the module and the type; that residue is judgement, and closing it is a behaviour change to the
rule, not an edit to a vendored copy.

## The escalation rule (R-10): a finding that cannot be fixed honestly is escalated

**Never suppressed.** Not with `@SuppressWarnings`, not with `// scalafix:ok` or `// scalastyle:off`, not by editing
`.scalafix.conf`, `wartremoverExcluded` or a style config, not by widening an allowlist, not by bumping a threshold,
not by excluding a file — at any scope, for any finding, under any deadline.

**Escalated** means stopped and asked, carrying the three facts that make the question answerable rather than a vote
(R-10, R-11):

- **the finding** — what the tool reported, where, and in the rule's own words;
- **the rule** — the `R-n` ID it violates and the layer that owns it;
- **the cost of each option** — reshape the code until it satisfies the rule; change the contract, if the rule is
  what is wrong; or accept the divergence and write it into the record as a ruling (R-12).

**Policy is per module.** A module that needs an exception removes the entry from *its own* list — its own
`baseAllowedTypes` override under Mill, its own `.scalafix.conf` under sbt, its own `shape-policy/*.conf` under
scala-cli. It never widens the base list other modules inherit, and never edits shared wiring to make one module's
diagnostic disappear. That is why the installer leaves the per-module half to the person shaping the module.

## The per-module half the installer leaves

The install writes the shared wiring — the rule, its registration, the tool classpath, the generated-config
machinery — and deliberately leaves each shaped module's own half to the person shaping it: which modules are
shaped, what their package roots are, what each module's list says. Where that half lives, per the recipes:

| Tool | Shared half (installed) | Your half, per shaped module | The check | The gate task |
|---|---|---|---|---|
| **Mill** | `scalafixRules/` (rule + registration), `buildKit/ArchitectureShapeModule.mill`, `ScalafixExtra.mill`, `build.mill`, `.scalafix.conf` | the mix-in in `build.mill`'s marked block — `object <module> extends Layer with ArchitectureShapeModule`, with its `packageRoot`, its own `baseAllowedTypes` and, where it differs, its own `disallowedConstructs`; the example ships commented | `./mill <module>.fix --check` (`./mill __.fix --check` for every module) | add it to the project's `preCommit` / `prePush` tasks in `build.mill` — `kit/recipes/mill.md:288` asks for exactly this, "so the check is not a command a human has to remember" |
| **sbt** | `scalafix-rules/` (rule + registration), the plugin line in `project/plugins.sbt`, the marked block in `build.sbt` | the opt-in in that block — ``.dependsOn(`scalafix-rules` % ScalafixConfig)`` — plus the module's own `.scalafix.conf`, whose `rules` must name `AllowedShape` and whose `AllowedShape` block is that module's list | `sbt "<module>/scalafix --check"` (or `sbt "scalafixAll --check"`) | the tasks or aliases your gate runs (`kit/recipes/sbt.md`, §4) |
| **scala-cli** | `.kit/arhitecture-shape/` and `allowed-shape.sh` | one `shape-policy/<directory>.conf` per shaped directory, both keys, passed to the runner | `sh allowed-shape.sh <sources-dir> <shape-policy/…conf>` | the project's own `preCommit` / `prePush` scripts call the runner per shaped directory |

For scala-cli the vendored `check.sh` is **not** the project's lint runner: it is the kit's own fixture check, whose
allowlist and expected counts are deliberately fixture-specific — they assert the kit's rule and its two fixtures,
not the project's policy. The project-facing mechanism is `allowed-shape.sh` plus the policy files.

Three spellings are frozen and identical in every tool: the rule name `AllowedShape`, the keys `allowedTypes` and
`disallowedConstructs`. The schema, the symbol-prefix semantics of `allowedTypes` and the own-package-prefix
convention are stated once in the enforcement README vendored with the wiring — read it there rather than from a
copy (R-12).

## Where the kit's pieces live

| Piece | Where |
|---|---|
| the rule, its registration, and the named blind spot | `kit/arhitecture-shape/` in the checkout; `.kit/arhitecture-shape/README.md` in an installed project |
| the build-tool wiring | `kit/recipes/mill.md`, `kit/recipes/sbt.md`, `kit/recipes/scala-cli.md`, and `kit/recipes/mill/ArchitectureShapeModule.mill` |
| the process skills | `kit/skills/*/SKILL.md`, installed to `.dsh/skills/` |
| the harness engine (L4) and its README | `kit/harness/` in the checkout (`kit/harness/README.md`); `.dsh/engine/` in an installed project, with `.dsh/engine/STAMP`; its Mill tasks in `kit/recipes/mill/Gate.mill` and `kit/recipes/mill.md` §7 |
| the agent-facing digest | `kit/digest.md`, planted into the project's `AGENTS.md` between the kit's markers |
| the `R-1 … R-14` rule list | the `scala-coding-guidelines` wiki, `wiki/reengineering/reengineering-contract.md`, pointed at by the digest planted in `AGENTS.md` |
| this procedure | `kit/apply.md` |
