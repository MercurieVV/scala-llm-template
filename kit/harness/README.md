# The harness engine — `kit/harness/`, vendored as `.dsh/engine/`

One gate (`.dsh/engine/gate.sh`) serves every hook of both dialects. This directory is the engine: the gate, its
hooks, `lib.sh`, `verify-diff.sh`, `module-map.sh`, `check-harness.sh`, `instructions-sync.sh` and the fixture
suites. It is edited **only** here, in `scala-llm-template/kit/harness/`, and vendored into each project as
`.dsh/engine/` by `install.sh` (spec `2026-09-26-harness-engine-vendoring-design`, Plan C v2). A project's own
`.dsh/README.md` documents the project's half — its contract values, its freezes, its policies, how it boots;
this file documents the engine every project shares. The reasoning behind each rule lives in the header of the
file that implements it — this is the map, not the argument.

## Layout

The engine directory is **the same tree** in both places: `kit/harness/` in the template (the source) and
`<project>/.dsh/engine/` (the vendored copy). So:

- **The engine finds itself from its own file, never from the repository.** A top-level script uses
  `engine=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)`; a hook uses the parent of its own directory; a test
  script under `tests/` uses `$(dirname -- "$0")/..`.
- **Project state is found from `gate_root`** (`GATE_ROOT` → `CLAUDE_PROJECT_DIR` → git toplevel → `PWD`), always
  under `<root>/.dsh/`: `contract`, `frozen-paths`, `policy/`, `instructions/`, `skills/`, `.state/`,
  `hooks.json`, `cc-settings.json`, and — for a DSH project — `dsh.sh` and `profile/`.
- **Engine files are never at `<root>/.dsh/<file>`.** They are `gate.sh`, `lib.sh`, `verify-diff.sh`,
  `module-map.sh`, `check-harness.sh`, `instructions-sync.sh`, `hooks/`, `tests/`, `README.md` and (vendored
  only) `STAMP`, all under `.dsh/engine/`.
- **The split rule:** what the engine reads at a fixed path under `.dsh/` is project state; everything
  executable is engine. `instructions/purrism.tsv` is project state — its version follows the project's purrism
  dependency.
- **Template-only paths** — `seed`, `install.sh`, `tests/install-test.sh`, `tests/smoke-second-project.sh` (lib.sh's
  `dsh_engine_template_only`,
  the one list both `install.sh` and check-harness group G read) — are part of `kit/harness/` but never of a
  vendored engine. A vendored engine therefore has no `install.sh`: to update one, re-run `install.sh` from a
  scala-llm-template checkout.
- **Frozen:** a project's `frozen-paths` carries `.dsh/engine/**`, so an agent never edits the vendored engine in
  place.

## Install and update

```sh
sh kit/harness/install.sh <project>      # run from a scala-llm-template checkout
```

- **The target must be a git repository** (exit `2` otherwise). `Setup.scala`'s `kit` feature runs this script as
  its `install-harness` step and initialises git in a brand-new target first (stderr: `initialised git in <dir> for
  the harness install`); its later `stage-git-changes` step skips `git init` when `.git` exists. Run by hand on a
  plain directory: `git init <dir>` first.
- **The engine is replaced wholesale**: built in a temporary directory beside the live one, the template-only
  paths and every `.DS_Store` stripped, stamped, then renamed into place. No merge, no stale file survives, and a
  copy that fails part-way leaves the previous `.dsh/engine/` untouched and complete.
- **Project state is seeded only where absent, never overwritten.** The seeds (`seed/`): `contract`,
  `frozen-paths` (containing `.dsh/engine/**`), `hooks.json`, `cc-settings.json`, `policy/allowed-types.tsv`,
  `policy/memorisation.tsv`, `policy/kernels.tsv` (header-only), `instructions/local.tsv` (with a `scalac.<kind>` row for each of the seven kinds in
  `instructions/scalac-kinds.tsv`), `instructions/scalac-kinds.tsv`. The seeded `frozen-paths` covers every path the
  installation checks require frozen (the self-freeze, `.ignore`, the instruction tables and `purrism.tsv`), so a
  fresh install's only installation FAIL is the absent `purrism.tsv` — `sh .dsh/engine/instructions-sync.sh` writes
  it once the build declares purrism. One line per file: `seeded`, `kept`, or `replaced` (the engine only).
  Because `frozen-paths` is kept, **a re-vendored project adds the new frozen-paths rows by hand (install.sh never
  overwrites frozen-paths)** — check-harness names each missing one (e.g. `.dsh/.state/contracts/**` once kernels are
  registered).
- **A gitignored engine file is named, never dropped silently.** After the swap, any vendored engine file the
  project's `.gitignore` matches is listed as `ignored  .dsh/engine/<path>`, followed by one remedy line on stderr
  naming the matching rule(s) — anchor it (an unanchored `out/` also matches the fixture trees under
  `tests/cases/*/root/out/`; write `/out/`) or add `!/.dsh/engine/**` after it. The exit stays `0` (the install
  itself succeeded), but a commit would drop those files and every clone's `STAMP` check (group G) would report
  the engine edited in place. `Setup.scala` writes an anchored `.gitignore` (`/out/`, `/.dsh/.state/`,
  `/.scala-semantic/`, …) for this reason.
- **`.claude/settings.json` is the human's step.** The installer seeds `.dsh/cc-settings.json`, the Claude Code
  wiring template; the human copies it to `.claude/settings.json` (`cp .dsh/cc-settings.json
  .claude/settings.json`, after merging anything already there). No script writes that file.

Exit codes:

| code | meaning |
|---|---|
| `0` | installed |
| `1` | usage, or the target is not a directory |
| `2` | the target is not a git repository |
| `3` | no sha256 tool (`shasum` or `sha256sum`) — the stamp cannot be written |
| `4` | the copy, the rename or the STAMP failed — the live `.dsh/engine` is untouched; **or** a seed failed — seeding runs after the swap, so the engine is already replaced and project state is partly seeded: fix the cause and re-run `install.sh` from a scala-llm-template checkout to finish seeding (seeds already present are kept) |
| `5` | not run from a scala-llm-template checkout (it must be `<toplevel>/kit/harness` and carry `seed/`); refused before any write, so a vendored copy can never re-stamp an engine edited in place as `ok` |

**`STAMP`**, three `key=value` lines written into `.dsh/engine/STAMP`:

| field | value |
|---|---|
| `template` | the template checkout's `HEAD` sha (40 hex), or `unknown` |
| `dirty` | `1` when the template's `kit/harness` had uncommitted changes, else `0` |
| `tree` | `dsh_engine_tree_hash`: sha256 over the sorted relative file list and each file's bytes, with the top-level `STAMP` and every `.DS_Store` excluded |

**The engine workflow:** edit `kit/harness/` in the template; run `sh kit/harness/tests/run.sh` there; commit;
`sh kit/harness/install.sh <project>`; commit the vendored copy in the project as `dsh: vendor engine <sha7>`.

**Migration note.** Engines vendored before template commit `41019a5` still carry `install.sh` and
`tests/install-test.sh` (the template-only list did not exist yet), so check-harness group D FAILs there — the
vendored `install-test.sh` calls a vendored `install.sh`, which refuses with exit 5 — until the project is
re-vendored.

## Drift

`check-harness.sh` is a host command:

```sh
sh .dsh/engine/check-harness.sh --project .          # the project's own vendored copy, the intended form
sh .dsh/engine/check-harness.sh --project . --full   # plus the opt-in clone suite
```

`--project <dir>` names the project whose installation is checked (default: `gate_root`). Run it as the
project's own vendored copy: run from another engine, it judges the **invoking** engine's hooks and suites but
the **project's** `.dsh/hooks.json` and `gate.sh` wiring, which is a mixed verdict.

Group **G** — the vendored engine:

| condition | verdict |
|---|---|
| tree hash = `STAMP.tree` | `ok   vendored engine matches its STAMP (template <sha>)` |
| `STAMP` missing | FAIL: re-run `install.sh` from a scala-llm-template checkout |
| tree hash ≠ `STAMP.tree` | FAIL: "vendored engine edited in place; edit in scala-llm-template/kit/harness and re-run install.sh from a scala-llm-template checkout" |
| no sha256 tool | FAIL: the vendored engine cannot be compared with its STAMP |
| `dirty=1` | note: vendored from an uncommitted template |
| `SCALA_LLM_TEMPLATE=<checkout>` set, and its `kit/harness` hash (taken like a fresh vendor: `dsh_engine_template_hash`, the template-only paths stripped) ≠ `STAMP.tree` | note: the template has moved ahead of the vendored engine — re-run its `install.sh` |
| the check runs from an unvendored engine (the template's own `kit/harness`) | note: no STAMP to compare |

**Health (SessionStart)**, for a vendored engine only (its physical path is `<root>/.dsh/engine`): a missing or
mismatching stamp is a note — `vendored engine does not match its stamp (<missing|mismatch|nohasher>); run sh
.dsh/engine/check-harness.sh` — never a block. The template's own test runs execute an unstamped `kit/harness/`
against scratch roots and print nothing.

## The contract

`.dsh/contract` is the project's gate interface, one `key = value` per line (`#` lines and blank lines ignored,
the first matching key wins, whitespace trimmed; `dsh_contract_get` / `dsh_contract_for_module`, which
substitutes `<module>`). The seed:

| key | seeded value | read by |
|---|---|---|
| `preCommit` | `./mill -j 1 preCommit` | the project's declaration (the kit's step 1 contract) |
| `prePush` | `./mill -j 1 prePush` | the same |
| `checkFormat` | `./mill -j 1 --ticker false <module>.checkFormat` | the same |
| `fix` | `./mill -j 1 --ticker false <module>.fix --check` | the same |
| `coverage` | `./mill -j 1 --ticker false moduleMap` | the same |
| `roots` | `.` | the same |
| `holdout` *(optional)* | — | `tool-policy` (refuses the agent running the sealed suite) and `turn-end` (runs it, reports names only) |
| `fastTests` *(optional)* | — | `post-edit`: per module, on any edit inside a `tests`-capable module; noted, never blocking |
| `turnEndTests` *(optional)* | — | `turn-end`: per module, blocking — for each touched module and, from spec 2026-10-01, for each touched module's dependents (the map's fourth column) |

The engine's hooks read only the three optional keys. The six base keys are the project's declaration of its
gate; the checks themselves call the Mill interface below by task name, which is why the engine supports Mill
only. A contract without `holdout` is legal but weaker, and check-harness says so in a note.

### `turnEndTests` time cap: `DSH_TESTS_CAP`

Spec 2026-09-28 §3: `turnEndTests` used to run with no cap of its own, and Claude Code kills a Stop hook at its
own 600 s timeout — a slow or hanging suite then ends the turn with NO verdict at all, not even a note. Each
module's run now goes through `dsh_bounded_probe`, capped at `min(DSH_TESTS_CAP (default 300), what is left of
DSH_STOP_BUDGET (default 540 s) since the hook started)` — one shared budget with the vericoding stage's own cap
below it, so a slow module leaves less for every module after it. With 10 s or less of the budget left when a
module's turn comes, it is not started at all. Either way the module is noted, never blocked — a run the hook did
not have time for was not verified, but it also did not fail:

| Condition | Note |
|---|---|
| no time left, or 10 s or less left, of the Stop-hook budget when the module's turn came | `turnEndTests: <module> not started — the Stop hook's budget` |
| the run hit its `DSH_TESTS_CAP` (or budget-shortened) cap and was killed | `turnEndTests: <module> did not finish within <N> s — not verified` |

`DSH_TESTS_CAP` accepts decimals only, leading zeros stripped, like every other knob here (`dsh_decimal`). The
vericoding stage's own budget rule is unchanged: it runs after the touched modules' `turnEndTests`, on whatever the
Stop hook's budget has left.

Dependents (spec 2026-10-01) share the same cap and the same budget, and run last — after the touched modules and
after the vericoding stage (final-review ruling F3, so Stainless keeps its share of the budget on a kernel edit): a
slow owner or a long Stainless run leaves less for the dependents, and each dependent's note reads
`turnEndTests: <D> (downstream of <M>) …`. They run only when nothing has blocked by then — a touched module's
checks, its `turnEndTests` or the vericoding stage.

## The Mill interface

The Mill interface is seven task names — an interface, not contract keys. The engine's hooks and scripts run the
first four by name; `preCommit`, `prePush` and `scalaSemanticWriteClasspath` are the project's declared gate
tasks, run by a human, a git hook or the contract's command lines — no hook runs them (see
[Running the engine's checks](#running-the-engines-checks)):

| task | run by |
|---|---|
| `moduleMap` | `module-map.sh` (→ `.dsh/.state/modules.tsv`: rows `<dir>` TAB `<id>` TAB `<capabilities>` [TAB `<dependents>`]; the optional fourth field, written by `Gate.moduleMapRows` from Mill's module graph, is a comma-separated, possibly empty list of the module ids whose `test` suite depends on this module, read by `module-map.sh --dependents <id>`) |
| `<module>.fixRanges --rangesFile <path>` | turn-end's rewrite stage |
| `<module>.fixStrict` | post-edit, turn-end |
| `<module>.compile` | post-edit, turn-end |
| `preCommit` | not the engine: the project's commit gate (a human, a git hook) |
| `prePush` | not the engine: the project's push gate (a human, a git hook); `tool-policy` runs `verify-diff.sh --staged` before it |
| `scalaSemanticWriteClasspath` | not the engine: the human, to write `.scala-semantic/classpath-mill.json` for ScalaSemanticMCP |

They ship as `kit/recipes/mill/Gate.mill` (`trait GateLayer` with `fixStrict` and `fixRanges`; `object Gate` with
`moduleMapRows` and `ClasspathMetadata`) plus the root-task fragments in **`kit/recipes/mill.md` §7**. Three
things §7 records because Mill measured them:

- the example's module type is a named `trait Formattable extends ScalaModule with ScalafmtModule`, because Mill
  1.1.8's build-file outline parser throws a NullPointerException on a compound `and`-type in a top-level `def`'s
  or `val`'s ascription;
- a `GateLayer` module's `.scalafix.conf` must name at least one rule, or `fix --check` (and so `preCommit` and
  turn-end) fails with `No rules requested to run`;
- a single Mill invocation of several tasks separates them with `+` (`./mill a.compile + b.compile`).

`kit/harness/tests/smoke-second-project.sh` assembles a scratch project from §7's own text and gates it end to end.
It is **template-only** (never vendored: it needs the template's `install.sh` and `kit/recipes/mill.md`) and
**machine-specific** and deliberately not a `*-test.sh` suite: it needs a global `mill` (1.1.8, which the
recipe's wrapper execs), the network for coursier, scala-cli, and it copies the Mill wrapper from a local skreeep2
checkout at a fixed path (falling back to a plain `exec mill` wrapper, and saying so, when that checkout is absent).

## Non-Mill projects

The rule is **positive evidence**: a project is non-Mill when `build.sbt` or `project.scala` exists at its root
**and** neither `build.mill` nor an executable `./mill` does (`dsh_non_mill_build`). A project with none of these
files is still treated as Mill — many fixtures rely on a `mill` stub on `PATH` and have no `build.mill` — so a
Mill project missing its wrapper still blocks at turn-end, as before.

For a non-Mill project the engine stands down, named, never silently and never with a block:

- `health` notes `gate engine supports Mill builds only; found: <build.sbt|project.scala> -- checks stand down`;
- `post-edit` allows with the same sentence (`… -- checks stand down for this turn`) before the module-map lookup;
- `turn-end` allows with it too, but only **after** diff-scoped verification, which is build-tool-agnostic and
  still runs — a `verify-diff.sh` block still blocks, and its notes ride along.

`Setup.scala`'s `install-harness` step skips any build tool other than Mill, by name.

## The exit-code contract

Every hook is `sh .dsh/engine/gate.sh <subcommand>` with the hook payload on stdin. The bridge reads only the
exit code:

| code | meaning |
| --- | --- |
| `0` | allow. The tool call proceeds. A hook may print an explanation on stdout. |
| `2` | block. The reason is on stderr and is what the agent is shown; the tool call does not happen. |
| anything else | a **non-blocking error**: the harness could not decide. Nothing is enforced, and the reason is in the message. |

Every hook fails **open with a reason** rather than closed without one: a read is denied only while
the semantic index is healthy, and then only for a file the index actually **covers**. A line naming
several files is denied as soon as ONE of them is covered; a line whose files are all unindexed
stands down with the file, its Mill module and the compile that would index it, because blocking a
read the semantic tools cannot answer for is a dead end rather than enforcement. Two bash shapes go
the other way and are DENIED as *undecided*: a line that changes directory while naming a
`.scala`/`.sc` path, and a token the classifier treats as a Scala operand that carries a glob
metacharacter — neither names a file the hook can resolve the way the shell would, so each is denied
with its ways out (name the path from the repository root, or use the semantic tools). A glob that does
not END in `.scala`/`.sc` (`cat engine/shape/src/*`, `cat dir/*`) never classifies, so it stays
readable, as it always has. A hook
that cannot parse its payload stands the whole gate down, and a delegated guard that crashes is
reported as broken infrastructure rather than as a verdict. The rule behind that is deliberate — a
gate that can deadlock a session is a gate that gets removed.

Probing a hook by hand (`tool-policy` here, any subcommand works the same way):

```sh
printf '{"tool_name":"bash","tool_input":{"command":"sbt compile"}}' | sh .dsh/engine/gate.sh tool-policy
echo "exit=$?"     # 2, with the Mill command that replaces sbt on stderr
```

`.dsh/engine/tests/run.sh` runs every fixture case this way, with `GATE_ROOT` pointed at a scratch root.

### The subs

`.dsh/hooks.json` (DSH dialect, lowercase matchers) and `.dsh/cc-settings.json` (Claude Code dialect, CamelCase
matchers; copied by the human to `.claude/settings.json`) are both seeded by `install.sh`. Every command in them is
`sh "$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh" <sub>`.

Both dialect files call the same gate with the same six seams: `health` and `baseline` on session start,
`tool-policy` and `semantic-guard` before a tool call, `post-edit` after a write, `turn-end` on Stop.
A matcher is matched case-sensitively against the tool name, so a CamelCase matcher in the DSH file
matches nothing, ever — the defect that motivated this harness. The project's own wiring suite (`wiring-test.sh`, beside its `.dsh/README.md`) pins
the vocabulary, the paths, the timeouts, the six seams and the absence of duplicates in both files,
and `check-harness.sh` group B cross-checks them against `gate.sh`'s dispatch.

Both files carry a second `PreToolUse` group for the semantic server's uri-carrying tools,
`mcp__[A-Za-z0-9_-]+__(annotated_source|source_around_position|source_ranges|document_outline|structure)`,
which runs `semantic-guard` too: the annotated write is refused on a frozen path, and a read of a
SEALED path is refused through all five. Symbol-based tools (`symbol_source`, `find_usages` with
`contextLines`, `search_text`) name a symbol, not a path, so a name guard cannot decide them; they
are out of scope, and a symbol defined in the sealed suite can surface through them. Its own group is deliberate:
the read/write matcher is a LITERAL alternation of tool names, and mixing a regex into that string
would turn every name in it into an unanchored regex (`Bash` would also select `BashOutput`, `read`
would select `mcp__idea__read_file`). The two matchers are disjoint, so a call still runs the gate once.

## Blind spots

The frozen-path layer (the project's `.dsh/README.md` has the freeze format and what it denies) matches
spellings, never meaning. What it cannot see:

**What this layer cannot see** — it matches *spellings*, never meaning, the same discipline C-9
states, and the denial message names these rather than claiming "any route":

* a path built at run time: `f=engine/details/x; cp /tmp/y "$f"`, `rm "$f"`;
* an interpreter that opens the file itself: `python3 -c "open(p,'w')"`;
* a patch whose target lives only inside the patch text: `git apply /tmp/p.diff`, `patch < p.diff`;
* a **symlinked** spelling of the path (`link/notes.md`), which nothing here follows;
* a `git` global option this layer does not know (it reads the short list `-c`, `-C`, `--git-dir`,
  `--work-tree`, `--namespace`, `--exec-path`, `--config-env` before the subcommand; another form is
  skipped as a bare flag) — the same wrapper-option class the read guard names for `bash -c 'sbt …'`;
* an option with a SEPARATE value in a `cp`/`mv`/`install`/`rsync` command (`install -m 755 <src>
  <dest>`, `rsync … --exclude foo`): the value is read as an operand, so a frozen path sitting after
  such a value can be refused where it is only read, and a value that is itself a frozen path is
  refused where it is only a filter. Both are the safe direction; name the destination first, or use
  an option that takes no value;
* the read side's own version of that gap: the bash **read** tokenizer drops any token starting with
  `-` outright, so `cat --file <path>` (separate value) is never seen as naming `<path>`. The
  `--opt=<path>` spelling is NOT in this class for the seal: the sealed-read tokenizer splits on `=`
  and `:` too, so `--file=holdout/x`, `git show HEAD:holdout/x` and `d=holdout; cat $d/x` each yield a
  `holdout…` token and are refused.

**Read-side blind spots** (the seal on `holdout/**` denies reads too, and these are the read routes a
name-matching guard cannot close):

* **symbol-based semantic tools**: `symbol_source`, `find_usages` with `contextLines`, `search_text`
  answer for a SYMBOL, and the uri they return is the index's, never the call's; a symbol the sealed
  suite defines can surface through them. The five uri-carrying tools ARE guarded (above). Note also
  that the guard's own stand-down hint, `./mill … __.compile`, indexes `holdout.test` too — and
  `tool-policy` refuses `__.compile` for exactly that reason while a `holdout =` line exists; compile
  the module you need by name instead (`./mill <module>.compile`).
* **spellings the shell resolves after the guard has looked**: a glob in a leading segment
  (`cat ho*/test/…`), a backslash inside the name (`cat hold\out/…`), brace expansion
  (`cat {holdout,app}/test/…`). The tokenizer sees the text as written, and none of those spells
  `holdout`; the sandbox is the layer under it.
* **`Glob` listing sealed file NAMES**: `glob` with a pattern anchored in `holdout/` is refused, but a
  pattern anchored above it (`**/*Holdout.scala`) lists the sealed files' names. Names only — the
  turn-end report already prints the failing test names — so this is accepted.

* **reads scoped at an ancestor**: `grep -r . `, `rg` where the root `.ignore` is not honoured
  (`rg --no-ignore`, a custom `--ignore-file`), `git grep <pattern>`, `git log -p`, `find . -exec
  cat {} +`. None of them names the sealed path — the search names the tree and the tool descends
  into it — so no text guard can see the sealed file in the command. The root `.ignore` (frozen)
  keeps `holdout/` and `.dsh/.state/holdout.log` out of ripgrep and of the ripgrep-backed `Grep`
  tool by default; the rest is the sandbox's and the reviewer's.

**Engine blind spots** (named here so none of them is a silent pass):

* **a `.scala` path in no module is skipped at turn-end without a note** — its module-map lookup is `-`, and
  turn-end skips it (`[ "$lookup" = "-" ] && continue`); no Mill task runs for it and nothing says so;
* **the tree hash has no per-file length framing and ignores file mode** — `dsh_engine_tree_hash` hashes each
  relative path, a newline, then the file's bytes, so a byte moved across a file boundary together with a matching
  rename could collide, and a `chmod` alone never changes the hash;
* **SessionStart health pays a full tree hash** of the vendored engine on every session start (about 4 s on
  about 2.6k files, measured), because the stamp note needs it.

## Frozen paths: what is caught where

Spec 2026-09-28 §§1–2 (roadmap item 9's follow-up): a frozen path is the human's in-flight work, and no agent may
write one — but "no agent may write one" is a claim about several independent layers, not one mechanism, and each
layer's own header states exactly what it can and cannot see. This table is the whole set, read top to bottom in
the order a write is actually caught (earliest first); a route not caught by an earlier layer is either caught by a
later one or is a documented blind spot below.

| Layer | Runs | Verdict | What it catches |
|---|---|---|---|
| Text rule — operand-shaped writes (`deny_frozen_operand`) | `tool-policy` (PreToolUse) | deny | `rm`, `mv`, `ln`, `truncate`, `patch`, `git checkout\|restore\|rm\|mv\|apply`, `perl -i`, `find -delete` / `find -exec rm` naming a frozen path as an operand (a relative operand after a literal `cd`/`pushd` is resolved against that directory first). |
| Text rule — semantic guard (redirections, `sed -i`-style writes) | `semantic-guard` (PreToolUse) | deny | the write shapes the operand rule's verb list does not cover — a shell redirection (`> <frozen>`, `>> <frozen>`) or an in-place stream edit. |
| Text rule — interpreter / inline shell (`deny_frozen_interp`, spec §2) | `tool-policy` (PreToolUse) | deny | the command's own TEXT names a frozen path (or a directory prefix of a frozen `**` row), and the command word is an interpreter with any arguments (`python`/`python2`/`python3`/`perl`/`ruby`/`node`/`pypy`/`nodejs`/`php`, version suffix stripped), or `sh`/`bash`/`zsh`/`dash` with `-c` (a combined short-option cluster like `-lc` counts too), or `awk`/`gawk`/`mawk`/`nawk` whose program contains `system(`, or `print`/`printf` together with `>` or `\|` anywhere in the whole command. A BARE wrapper word with no option of its own (`env`, `command`, `exec`, `sudo`, `time`, `nohup`, `xargs`, including a path-qualified `/usr/bin/env`; `nice` too, though it is not one the shared parser itself skips) is transparent — the rule sees through it to the real interpreter — and so is a leading shell variable assignment (`PYTHONPATH=. python3 -c …`, `A=1 B=2 sh -c …`), handled locally in this rule. The shared parser also skips each wrapper's OWN options (`sudo -u x …`, `sudo -E …`, `env -i …`, `nice -n 5 …` / `nice -n5 …`, `time -p …`, `xargs -I{} …`, `timeout [-s SIG] [-k DUR] DURATION …`, `stdbuf -oL …`, `busybox <applet> …`), so those are seen through too (measured: all denied for a frozen target), and the code given to `eval` / `sh -c` is judged as a command of its own. **Reads are denied too** — the rule is text, not semantics, so it cannot tell a read from a write; the message points the agent at the Read tool instead. |
| Post-hoc check — tracked/untracked frozen files (spec §1 item 1) | `turn-end` (Stop), first thing, before every other stage | block | every path `dsh_changed_paths` reports (git edits, deletions, new files, both names of a rename) that this SESSION changed (baseline-scoped: a path already dirty at SessionStart counts only if its hash moved since; new-since-baseline always counts) and a frozen row answers for. This is the route-independent layer: it does not care which of the text rules, if any, the write went through. It also catches a frozen path dirty at SessionStart that git no longer lists — reverted to a *different* content than the baseline recorded (an ungated `git checkout`/`git restore`) — in session-baseline mode only. |
| Git-ignored frozen files (spec §1 item 2) | `baseline.sh` records at SessionStart; `turn-end` re-hashes at Stop | block / note | git cannot see a git-ignored file, so the check above never lists one. SessionStart hashes every existing git-ignored file a frozen row answers for into `.dsh/.state/frozen/<key>.tsv` (`<sha256> TAB <path>`; always written, header-only if none). At turn-end each recorded file is re-hashed: changed or missing content → **block** (`frozen path changed/removed this turn: <path>`); a file **added** under a frozen row since SessionStart → **block** (`frozen path added this turn: <path>`); the record itself absent → **block** (`frozen record missing: <path>`) only when this session's own baseline header ends ` frozen-record` (proof this session's SessionStart wrote one) — without that proof it is a **note**, never a block, because an older engine or an unwired SessionStart cannot be blamed for a record it never promised; `incomplete:` in the record's header, or no sha256 tool, → a **note** (`frozen ignored paths not compared`) — the rows it did record are still compared. |
| The gate's own writes | `dsh_gate_written` (lib.sh), read by every layer above that walks changed/ignored paths | excluded | `.dsh/.state/receipts`, `modules.tsv` (+ its temp), `holdout.log`, `unverified.log`, `health` (+ its temp), `index-coverage` (+ its temp), `turn-end-*`, `baseline-*`, `contracts/*`, `frozen/*`, `feedback/*`, `instructions-missing`, `memo-testvals.*`, `semantic-fallback.log`, `green/*` — the gate's own bookkeeping under `.dsh/.state`, never read as an agent's write to a frozen path. A session's own `contracts/<key>.tsv` and `frozen/<key>.tsv` stay IN scope once a comparable baseline holds their hash (they are the human's record from that point on). Excluding these BY NAME is also a gap: an interpreter's WRITE to `.dsh/.state/receipts` or `.dsh/.state/modules.tsv` through a path it computes at run time is not distinguishable from the gate's own write, so when `.dsh/.state` is git-ignored (the common case) such a write is not detected by anything in this table. |
| `.claude/settings.local.json` exemption (human decision, final-review fix pass) | `turn-end` (Stop), inside the frozen stage | note, not block | this one exact path is seed-frozen (`.claude/settings.local.json`) and usually git-ignored, but Claude Code itself rewrites it whenever the human picks "don't ask again" on a permission prompt — a write neither an agent's edit nor a stale baseline. A finding for exactly this path (tracked or git-ignored; changed, removed or added) is filed as a NAMED NOTE (`frozen path <how> this turn: .claude/settings.local.json (noted, not blocked)`) instead of a block; every OTHER finding in the same turn still blocks normally. **Cost:** an agent that itself rewrites this file through a route the text rules cannot see (an interpreter, a computed path) is also only noted, not blocked — the same blind spot as any other git-ignored frozen file, deliberately accepted here because the file is rewritten by Claude Code's own permission UI often enough that blocking it made every later turn unusable. The tool-policy text rules are unchanged: an agent's Write/Edit, or an interpreter/inline-shell text rule match, naming this path is still denied before it lands. |

**No frozen rows at all** → nothing above is read, checked or recorded beyond a header-only git-ignored record; a
frozen path cannot be violated by a project that has none.

**Remedy, every block above (except the one exemption just above):** the agent cannot restore a frozen file —
writing it is what the freeze denies. Stop and ask the human; `git diff HEAD -- <path>` (or `git status -- <path>`
for an untracked one, or "git cannot show it, the file is git-ignored" for a `.dsh/.state` record) shows what
changed. If the human restores the file, that clears the block. If the human instead KEEPS the change, the block
does not clear at once:
- for a **tracked** file that was CLEAN at SessionStart (including the human's own edit to
  `.dsh/frozen-paths` itself, to unfreeze a path), it stays blocked until the human COMMITS it — a kept,
  uncommitted change still differs from `HEAD`, which is what this check compares against;
- for a **git-ignored** file, it stays blocked until a NEW SESSION starts — SessionStart is what takes a fresh
  hash record of every git-ignored frozen file, and only that fresh record stops reading a kept change as new;
- for a **tracked file that was already DIRTY at SessionStart** (the human's in-flight work), committing does
  **not** clear it either, and neither does restoring the file to `HEAD` — this comparison is against the
  file's content AT SESSION START (the SessionStart baseline row), never against `HEAD` (final-review fix pass,
  I2 residual: an earlier version of this fix named "the human commits it" as the remedy for every tracked
  file, which is wrong for this one). Once the further edit is committed, `git diff HEAD` can show nothing at
  all even though the block persists. To clear it: restore the exact content the file had at SessionStart, or
  start a new session — a new session takes a fresh baseline of whatever is dirty then.

"The human restores or keeps it" (an earlier wording of this remedy) undersold the "keeps it" branch: kept does
not mean cleared, and which condition clears it depends on whether the file was clean or already dirty when the
session started. The existing turn-end attempt cap (two blocked attempts, then a logged release) applies to a
frozen finding like any other block.

### Documented blind spots and limits

* **An interpreter with arbitrary code can rewrite both a git-ignored frozen file and its hash record.** The
  record is frozen against Write/Edit and the text rules, not against an interpreter that computes its own path at
  run time; only a sandbox closes this.
* **Computed paths, and an interpreter run from a script file rather than inline, are not caught by either text
  rule** (`deny_frozen_operand`'s and `deny_frozen_interp`'s own messages name this) — the post-hoc turn-end check
  is the layer that answers for both.
* **Wrappers are seen through with their own options** (the wrapper-bypass fix): `env [-i] [-u NAME] [NAME=value]…`,
  `timeout [-s SIG] [-k DUR] DURATION`, `nice [-n N]`, `time [-p]`, `sudo [-u USER] [-E]…`, `nohup`, `exec [-a NAME]`,
  `stdbuf -oL`, `ionice`, `xargs` with its value-taking options, `busybox <applet>`, chains of them, and a leading
  `NAME=value` assignment. The code given to `eval '…'` or a shell with `-c` (`sh -c`, `bash -lc`, …) — bare or behind any
  of those wrappers (`nice -n 5 eval '…'`, `timeout 5 sh -c '…'`) — is appended to
  the line and judged by every rule as a command of its own (nested up to three levels). A command word the shell
  computes at run time inside that code (`sh -c "$CMD"`, `eval "$(cat run.sh)"`, a backquote) is refused, since
  text cannot judge it. Still outside this layer: a shell alias or function, and a script file the interpreter runs
  (the post-hoc turn-end check answers for a TRACKED file either way).
* **`tee <frozen>` and `cp`/`mv`/`install`/`rsync` onto a frozen destination ARE denied** — by the semantic guard's
  bash-action-path scan (`dsh_bash_action_paths`: `tee`'s every non-option operand, and `cp`/`mv`/`install`/
  `rsync`'s destination operand), not by the interpreter rule or the operand rule. (An earlier draft of this note
  said `tee` was not denied by either text rule; measured against the code, it is — by this third one.)
* **The fallback baseline modes (`tree`, `nohash`, `unreadable`) cannot detect a revert of a pre-dirty frozen
  file** — only the `session` baseline state carries a per-path hash to compare a reverted file's content against;
  in every fallback mode there is nothing recorded to tell "reverted to the human's own content" from "reverted to
  something else."
* **A row added to `.dsh/frozen-paths` mid-session misses a pre-dirty non-Scala file it now covers**: the
  SessionStart baseline recorded frozen dirty paths against the frozen list AS IT WAS at session start, so a
  non-Scala file that was already dirty under the OLD list has no baseline hash row under the NEW one — turn-end
  cannot tell "already dirty, untouched" from "changed this session" for it.
* **After the attempt cap releases, other checks are skipped while the frozen finding persists.** The frozen stage
  runs first and blocks straight through `block()`; when the cap is reached `block()` releases the turn via
  `allow` immediately (measured: `allow` exits the script on the spot), so diff-scoped verification, the compile
  chain, `turnEndTests` and vericoding never run that turn. The attempt counter resets on release, so the next
  turn hits the same frozen finding first again — the sequence repeats for as long as the frozen change stays.
* **A filename with an embedded newline under a git-ignored frozen directory is not protected** —
  `dsh_frozen_ignored_files` enumerates such a directory with `find … -print`, one path per line, so a newline
  inside a name breaks the per-line parsing.
* **A `.DS_Store` or other OS write under a git-ignored frozen directory blocks, like any new file** — it is
  caught by the "added since SessionStart" check, not exempted, so an agent (or the sandbox) that creates one
  there blocks the turn exactly as an intentional write would.
* **Deleting a PARENT directory of frozen rows is text the frozen-path checks never see as a frozen-path write**:
  `rm -rf .dsh` or `shutil.rmtree('.dsh')` names `.dsh`, not any row under it, so no text rule matches. A TRACKED
  file the deletion took with it still shows up at turn-end (`dsh_changed_paths` reports the deletion of every
  file git tracked under the removed directory, and each one is checked against the frozen rows as before); a
  git-ignored one is a genuine gap the same as any computed-path write above.
* **`cd .dsh && python3 -c "open('contract','w')"` names no frozen path in the command's own text** — the
  operand is `contract`, relative, spelled only after a `cd` the interpreter rule's text scan does not resolve
  (unlike the operand rule, which does resolve a literal `cd` first). Turn-end still catches it for a TRACKED
  file, the same as any other interpreter write the text rules miss.
* **The interpreter text rule over-blocks** (the trade-off its own header states — text, not shell semantics):
  * an `awk`/`gawk`/`mawk`/`nawk` invocation with `print` or `printf` plus a `>` or `|` **anywhere in the whole
    command** — not necessarily in the same awk program, or even the same pipeline segment;
  * a path under **another** directory that merely shares a frozen prefix row's spelling as a path token, e.g.
    `vendor/engine/details/…` against a frozen `engine/details/**` row — the boundary check treats `/` as a
    token boundary on both sides, not as "this IS the repository-rooted directory";
  * a `sh`/`bash`/`zsh`/`dash` command whose own script takes a single-dash argument containing the letter `c`
    (`sh myscript.sh -check`) — read as a combined `-c` cluster, though the script never runs inline code.
* **Transitional note: a mid-session re-vendor leaves dirty non-Scala frozen files unrecognised until they are
  committed.** A session started under the OLD engine (before this fix pass) has no baseline rows for a frozen
  file that was already dirty and is not `.scala`/`.sc`/`.mill` — the SessionStart baseline this fix pass's
  `turn-end` reads was taken by code that did not yet record it. Such a file then reads as "new since the
  baseline" and blocks until the human commits it, even with no in-session write of its own. Re-vendor BETWEEN
  sessions, not mid-session, so every session's SessionStart baseline matches the engine that reads it.

## Diff-scoped verification: `verify-diff.sh`

`sh .dsh/engine/verify-diff.sh [--staged|--staged-worktree]` (spec 2026-09-24) is a cheap, deterministic
check that runs BEFORE the per-module compile chain, both at turn-end (against the gate's baseline)
and — via `--staged` — from `tool-policy` before `git commit` / `./mill prePush` (against the
INDEX). `--staged-worktree` is the same boundary against `git diff HEAD` instead of the index, and
`tool-policy` uses it for the commit spellings that stage AFTER the hook has run: `git commit -a` /
`-am` / `--all` / `--include`, and `git commit <path>`. Without it those forms read an empty index,
exit 0 in silence, and commit unchecked. It checks four things, the first three scoped to the lines
the diff actually changed, never the whole file:

1. **Every name a changed line introduces resolves.** `resolve_references` (ScalaSemanticMCP) is
   asked about exactly the changed ranges in every `.scala`/`.sc` file the diff touches; an
   unresolved name blocks, with the tool's own near-miss suggestion when the index has one
   (`did not resolve — did you mean: p/A.bonusThing().`) or a plain "no near-miss in the index"
   when it doesn't.
2. **Every resolved symbol is one the module's policy permits** — `.dsh/policy/allowed-types.tsv`,
   below.
3. **Every dependency coordinate a changed build line adds resolves**, via `cs resolve` (`+` lines
   in `build.mill`/`build.sbt` only; a removed coordinate is never checked).
4. **No construct this turn touched has memorised the tests** — a production construct whose
   literals are largely the visible tests' own values blocks, at both boundaries. It is judged on the
   WHOLE construct once any of its literals is on a changed line; see
   [the memorisation check](#the-memorisation-check) below.

**What this deliberately does NOT check.** Types, exhaustivity and effect discipline are not this
gate's job and never will be — they stay with `./mill <module>.compile` (types, exhaustivity),
`fixStrict` (the purrism rewrites) and the holdout suite (effect discipline, property tests). This
gate answers exactly one question per finding — "does this name exist, and may this module name
it" — and stops there; it is not a second compiler and does not try to be one.

**`.dsh/policy/allowed-types.tsv`** is the human's table: one `#`-headed TSV, one row per allowed
prefix, three TAB fields — `<module dir> TAB <allowed symbol prefix> TAB <reason>`. A worked row:

```
engine/shape	skreeep2/engine/shape/	the shape layer names only its own types
```

reads as: code under `engine/shape` may name any symbol whose SemanticDB path starts with
`skreeep2/engine/shape/`, and nothing else — a second row adds a second allowed prefix for the
same module (e.g. letting `engine/shape` also speak `skreeep2/engine/api/`, a published surface).
A module with NO row in the table has no policy and nothing is refused for it; `scala/`/`java/`
symbols are always allowed regardless of the table, decided from the tool's own `origin: stdlib`
before the table is even consulted. `dsh_policy_allows <symbol> <module-dir> [root]` (lib.sh) is
the one function both `verify-diff.sh` and its tests call to answer this.

**Turn-end notes; a commit blocks — but only for FINDINGS.** A turn is a work-in-progress
checkpoint — an agent may end one with a name that doesn't resolve yet, mid-refactor, and the gate
says so as a NOTE rather than stopping the session. A COMMIT is what the repository keeps, so at the
repository boundary (`git commit`, `./mill prePush`) `verify-diff.sh --staged` promotes every
FINDING — including the ones that only note at turn-end — to a block.

A **finding** is something the gate found WRONG and the agent can fix: an unresolved name, a policy
violation it trusts, a coordinate that does not resolve, an unresolved name repeated in prose. A
**degradation** is the gate saying "I could not check": no `timeout` on PATH, no launcher, no `cs`,
a Scala file the tool did not answer for, a turn with no Scala file to hang the prose check on, a
policy violation it cannot trust because there is no SemanticDB index, more changed Scala files than
one call may carry. **Degradations never promote to a block, at either boundary.** They are printed
either way, so the commit that goes through still says what about it was not checked. The reason is
concrete: this machine has no `timeout` on PATH, so before the split every staged commit touching a
Scala file — and every `.md`-only commit, via the prose NOTE — was denied with a reason no edit the
agent could make would ever clear. A denial the agent cannot act on is worse than the silent pass
this gate exists to remove.

**Every NOTE the gate can print, and what it means** (the table is the whole set: every `dnote` and
every `section note` in `verify-diff.sh`, the bare lines it prints before its section machinery runs,
and every non-blocking section `turn-end.sh` files — its own `section note` calls and the headers of
its `vd_note`/`rw_note`/`vk_note` — plus the two notes vendoring added, printed by `health` and by the non-Mill
stand-down. A NOTE not listed here is a bug in this table). **Kind** is the split above:
a *finding* is something wrong the agent can fix; a *degradation* is "this was not checked", and never
promotes to a block. The `<module>`, `<check>` and `N` parts of a title are filled in at run time.

| NOTE | Printed by | Kind | Meaning |
|---|---|---|---|
| `verify-diff: the root … cannot be entered — nothing was checked.` | verify-diff | degradation | the gate root does not exist or cannot be `cd`-ed into; printed bare, without a section header, because nothing — not even the section machinery — had run yet. Exit 0. |
| `diff-scoped verification (not run)` | verify-diff | degradation | git itself could not be read; the changed-line ranges are unknown, so nothing was checked (never a block). |
| `diff-scoped verification (truncated)` | verify-diff | degradation | more than 50 Scala files changed in one turn; the 50 with the most changed lines were checked, the rest were not. Its own words are "not checked", and no edit clears it; only abandoning the shape of the commit would, and a 51-file mechanical rename is a legitimate commit. |
| `diff-scoped verification (partial)` | verify-diff | degradation | the semantic call itself degraded: no launcher, the 30 s cap couldn't be applied (no `timeout` on PATH), the call timed out or errored (no classpath metadata is the common case), or neither `jq` nor `python3` was available to read its answer; or the call ran but answered a per-file error for a changed file (`the semantic check did not run for <uri>: <reason>`), so that file's names were not checked. |
| `names in Scala files (not checked)` | verify-diff | degradation | a Scala file was SENT to `resolve_references` and did not come back in the response's `files[]` at all (empty stdout, `{"files":[]}`, a dropped entry) — the names in it were not verified. A file answered with `"references": []` (a comment-only, format-only or deletion-only change) is ANSWERED and never listed here. |
| `symbols outside the module's allowed prefixes — NOT blocking, there is no SemanticDB index yet so a symbol's origin cannot be trusted` | verify-diff | degradation | a policy violation was found, but with no SemanticDB index a symbol's `origin` (project vs. elsewhere) cannot be trusted, so the finding is downgraded rather than blocked on a guess. |
| `dependency coordinates (not checked)` | verify-diff | degradation | no `cs` (coursier) on PATH; added coordinates are named but never resolved. |
| `memorisation (not checked)` | verify-diff | degradation | the memorisation check did not run at all, and the body says why: the module map (`.dsh/.state/modules.tsv`) is not built yet, so no test source could be identified (a fresh clone's first turn); no launcher; `literal_tokens` failed for the test or for the changed sources; its answer was not a readable `literal_tokens` answer; or neither `jq` nor `python3` is there to read it. |
| `test source(s) could not be read for literals` | verify-diff | degradation | the check ran, but these test files came back with an error, no entry, or an `omitted` count: the test literal set is incomplete, so an overlap may be undercounted. This partial set is not cached, so the gap never outlives the turn. |
| `changed source(s) could not be read for literals` | verify-diff | degradation | the check ran, but the constructs in these production files were not judged (the whole file on an error or a missing entry, the literals past the tool's 2000-per-file cap when partly read). |
| `names in prose (not checked)` | verify-diff | degradation | see below — the turn changed no Scala file, so prose could not be checked at all. |
| `names in prose that do not resolve (not blocking)` | verify-diff | finding | a name the semantic check already found unresolved also appears in an added prose line (`.md`, a comment-only diff); noted at turn-end. `--staged` promotes it to a block. |
| `verify-diff.sh exited N, so the names this turn introduced were NOT checked:` | turn-end | degradation | `verify-diff.sh` itself failed (neither 0 nor 2); its output follows. A header line, not a `--- … ---` section. |
| `purrism rewrites skipped` | turn-end | degradation | the rewrite stage did not run, for one of two reasons the body names: no usable SESSION baseline (no record, an unreadable one, or no sha256 tool), or this turn-end is at the attempt cap and would release the turn unreviewed. Printed only when a touched module grants `scalafix`. `fix --check` still gates every module. |
| `purrism rewrites (not applied) in <module>` | turn-end | degradation | some or all of this module's changed lines were not rewritten, and the body says which of three reasons: the file was already dirty at SessionStart (its diff mixes your lines with a human's); its original could not be saved, so a rewrite of it could not be undone; or `<module>.fixRanges` exited non-zero (its first lines follow). `fix --check` still gates it. |
| `purrism rewrite reverted in <module>` | turn-end | degradation | the rewrite was applied, the module then failed to compile, and every file of the module the rewrite changed got its original back; the first compile error follows. If the ordinary compile later in the chain passes, that was a purrism bug, not your code. |
| `<check> (failed; names only files this turn did not touch — not blocking)` | turn-end | finding | a check in the compile chain failed, but every file its output names is one this turn did not touch — real breakage, attributed elsewhere, so it notes instead of blocking (F53). |
| `Source files this turn deleted …` / `<module> lost <path>` | turn-end | — (a header line, in the block and in the green message) | this session deleted a `.scala`/`.sc` file (a plain or staged delete, or the old name of a rename or move). The module that owned it is checked as if it were touched — its compile chain, then its dependents' `turnEndTests` — and any diagnostic naming a file under that module's directory blocks, because a deletion's errors name the files that used it. The cost: breakage already present elsewhere in that module blocks too. A file already deleted at SessionStart is not this session's (baseline.sh records it as `-`). The module's remedy line adds `this turn deleted <path> — restore it … or update the code that used it`. |
| `turnEndTests: <module> (N draft failure(s) — noted)` | turn-end | finding | the module's turn-end tests failed only on DRAFT properties/tests, which note rather than block. |
| `turnEndTests: <module> not started — the Stop hook's budget` | turn-end | degradation | either no time was left of `DSH_STOP_BUDGET` (default 540 s) when the module's turn came, or 10 s or less were left; either way its `turnEndTests` were not started this turn. See [`DSH_TESTS_CAP`](#turnendtests-time-cap-dsh_tests_cap). |
| `turnEndTests: <module> did not finish within <N> s — not verified` | turn-end | degradation | the run was killed at the `<N>` s cap (`DSH_TESTS_CAP`, default 300, bounded by what was left of `DSH_STOP_BUDGET`) and never reached a verdict. Not counted as a failure. |
| `turnEndTests: <D> (downstream of <M>) (failed)` | turn-end | finding (blocks — a blocking section, listed here beside its notes) | `<D>` was not touched, but it depends on the touched module `<M>`, and its `turnEndTests` failed on a non-draft record. Blocks, and counts toward the attempt cap. The body ends with `` `<D>`'s tests fail after your change to `<M>` — if they also fail without it, or encode behaviour you were asked to change (its tests are frozen), stop and tell the human; otherwise fix `<M>`; reproduce with `./mill <D>.test` ``. Run only when nothing has blocked by then (a touched module's checks, its `turnEndTests`, the vericoding stage), after the vericoding stage, and only for a touched module with at least one touched file outside its `test/`. |
| `turnEndTests: <D> (downstream of <M>) green` | turn-end | — (a green line, listed here beside its notes) | a dependent's `turnEndTests` passed. Listed with the other greens. |
| `turnEndTests: <D> (downstream of <M>) (N draft failure(s) — noted)` | turn-end | finding | a dependent's `turnEndTests` failed only on DRAFT properties/tests; noted, never blocking. |
| `turnEndTests: <D> (downstream of <M>) not started — the Stop hook's budget` | turn-end | degradation | as for a touched module: 10 s or less of `DSH_STOP_BUDGET` was left when the dependent's turn came. Dependents share the owners' cap and budget, after them. |
| `turnEndTests: <D> (downstream of <M>) did not finish within <N> s — not verified` | turn-end | degradation | as for a touched module: the dependent's run was killed at its `DSH_TESTS_CAP` (or budget-shortened) cap. Not counted as a failure. |
| `downstream turnEndTests not run — <owner> failed first (<n> modules waiting)` | turn-end | degradation | something blocked before the dependents' turn — a touched module's checks (`compile`, `checkFormat`, `fix`, …), its own `turnEndTests`, or the vericoding stage — so none of the `<n>` dependents were run: fix that first. `<owner>` is the module whose `turnEndTests` blocked, else the first module in the block's list. A report line, not a `--- … ---` section. |
| `<n> downstream modules not run — fix this one first: <id> …` | turn-end | degradation | a dependent's `turnEndTests` blocked, and the `<n>` dependents after it were not run; their ids follow, in run order. A report line, not a `--- … ---` section. |
| `frozen ignored paths not compared` | turn-end | degradation | the git-ignored frozen-file record (`.dsh/.state/frozen/<key>.tsv`) could not be fully compared this turn: no sha256 tool, the record itself is `incomplete:` (SessionStart could not hash every git-ignored frozen file), or the ignored-file list could not be re-enumerated to catch one ADDED since SessionStart. The rows it did record (or list) were still compared. See [Frozen paths: what is caught where](#frozen-paths-what-is-caught-where). |
| `vendored engine does not match its stamp` | health | degradation | the vendored `.dsh/engine/` is missing its `STAMP`, no longer matches it, or cannot be hashed (the parenthesis says which). The gate still runs; `sh .dsh/engine/check-harness.sh` FAILs on the same condition. Remedy: re-run `install.sh` from a scala-llm-template checkout. |
| `gate engine supports Mill builds only` | health, post-edit, turn-end | degradation | positive evidence of another build tool (`found: build.sbt` or `found: project.scala`, and no `build.mill` or `./mill`): the Mill checks stand down, named. At turn-end, diff-scoped verification has already run. See [Non-Mill projects](#non-mill-projects). |
| `vericoding: <m> — <N> verification condition(s) unknown (solver timeout)` | turn-end | finding | Stainless could neither prove nor refute these VCs within its per-VC timeout; each is listed as `<file>:<l>:<c>  <fn>  <vc kind>  (timeout)`. The human decides whether to accept them. See [Vericoding](#vericoding-contracts-are-the-humans-stainless-checks-the-body). |
| `vericoding: no contract snapshot for <files>` | turn-end | degradation | the session's contract snapshot does not cover these touched kernels (recorded `incomplete: <reason>`, which the body quotes, or registered since), so their contracts were not compared. Stainless still runs. |
| `vericoding: contract guard stood down` | turn-end | degradation | `contract_clauses` could not be asked or read: no launcher, a failed call, a per-file error, no JSON reader, or an answer that is not JSON. Contracts were not compared; Stainless still runs. |
| `vericoding: contract guard cannot compare <key>…` | turn-end | degradation | a clause has neither a shape nor a text in the snapshot or in the answer, so it was not compared. |
| `vericoding: Stainless could not run for <m>` | turn-end | degradation | the verify script reported `SETUP —` (a download, launcher or java failure, no summary), printed no marker, or said `OK` while Mill failed. The kernels were not verified; this is not a verdict on the body. |
| `vericoding: Stainless did not finish for <m> within <N> s — not verified` | turn-end | degradation | the run hit its cap (`DSH_STAINLESS_CAP`, default 480 s, or what was left of the Stop budget) and was killed. |
| `vericoding: no time left to run Stainless for <m> (the Stop hook's budget) — not verified` | turn-end | degradation | 10 s or less of `DSH_STOP_BUDGET` (default 540 s) was left, so the run was not started. |
| `vericoding: Stainless not run for <m>` | turn-end | degradation | the module's own checks already blocked this turn, so neither the contract guard nor Stainless ran on its kernels. |

`purrism rewrite reverted in <module>`, and `purrism rewrites (not applied) in <module>` after a failed
`fixRanges`, can end with `COULD NOT RESTORE the original of <files> … — restore it by hand.`: a restore that failed is
named inside the note, never dropped. Two lines turn-end prints are not NOTEs and so are not in the
table: the `Session baseline: …` / `No SessionStart baseline …` line that says which scoping rule
produced the verdict, and the closing tests line — `Tests are NOT run by this gate` when no
turnEndTests ran, `Of the tests, only the turnEndTests reported above ran here (<modules>)` when some did.

**The prose check's real limit — read this before assuming more than it does.** The spec first
imagined prose verification as its own thing; in practice `resolve_references` answers only about
Scala files, so prose can only ever be checked by reusing the unresolved names the *Scala* half of
the same turn already found — there is no independent path to naming-check a `.md` file or a
comment on its own. The direct consequence: **a turn whose changed lines touch no Scala file but DO touch a
prose file produces the `names in prose (not checked)` NOTE and nothing else prose-related** — not
a false "all clear," an honest "not checked, and here is why." Do not read the absence of a prose
finding as prose having been verified; it means either nothing in the diff's prose named something
already known to be broken, or — the common case — there was no Scala change to derive broken
names from in the first place.

The NOTE is hung on the prose FILES, so a turn with no prose file to name produces nothing at all:
a `build.mill`-only turn is not prose (build files go to the dependency check, not the prose one),
and if its changed lines add no coordinate, the dependency check has nothing to say either — that
turn prints nothing, measured. It is the one shape of change this gate is silent about.

**Suggestions are printed, never applied.** The near-miss text after "did you mean:" comes straight
from `resolve_references`'s own answer; nothing in this gate edits a file, retries a name, or
proposes a patch. Applying a suggested correction automatically is explicitly out of scope — the
gate's whole contract is "block and say why," and every fix stays the human's or the agent's own
next edit.

**`check-harness.sh`** (`dsh_verify_checks`) enforces the installation, one `ok`/`FAIL`/`note` row
per rule: `.dsh/engine/verify-diff.sh` present and executable (FAIL if not — a missing gate script is a
FAIL, never a silent stand-down); `.dsh/policy/allowed-types.tsv` parses when present (a `note` when
there is none at all, and the same `note` when it is present but has no rule rows — both are the
state "no module has a policy and none is enforced", and one state must not report two verdicts);
both are frozen paths (FAIL if not); `.dsh/policy/memorisation.tsv` parses and is frozen (see
[its rules](#installation-rules-for-both-stages) below); and what the gate can actually reach on THIS
machine — no `scalasemantic-mcp` launcher, a launcher too old for `call`, a launcher that does not
answer `call literal_tokens`, no `.scala-semantic/classpath-<tool>.json` classpath metadata, or no `cs`
on PATH are each their own `note`, because a gate that cannot reach its tools degrades to noting
rather than checking, and that degradation is a fact about the machine, never a silent pass.

The launcher rule PROBES rather than trusting `-x`: it runs `scalasemantic-mcp call
resolve_references '{"files":[]}' <root> </dev/null` once. The probe is bounded without `timeout`
(absent on stock macOS) by `dsh_bounded_probe` (lib.sh): it runs in the background, is polled for at
most 20 s and killed if it is still there, and a probe that had to be killed is its own `note` — so a
wedged launcher can never hang `check-harness.sh` or `lib-test.sh`.

What the probe keys on was measured, not assumed. A launcher older than the one-shot `call`
subcommand falls through to `serve`, reads EOF on the closed stdin and exits 0 printing nothing on
stdout — the configuration that produced this gate's own silent pass (the installed jar was
`scalasemantic-mcp-0.5.0-local.jar`), and one `-x` alone reports as healthy. A CURRENT launcher
rejects the probe's empty `files` list: rc 1, empty stdout, and `resolve_references failed: …
files must hold at least one …` on stderr. So stdout alone cannot be the test — keying on it
reported every current launcher as stale — and neither can "any stderr", because both jars print the
JVM's own `WARNING: … sun.misc.Unsafe` lines there. A launcher has `call` when it prints on stdout
or names `resolve_references` on stderr.

The launcher and the classpath are independent facts and are reported independently. The server
DISCOVERS its classpath from `.scala-semantic/classpath-<tool>.json` under the workspace root (see
ScalaSemanticMCP's `docs/getting-started/integration.md`); the harness passes none. Without that
metadata the presentation compiler cannot start, and the one-shot call exits 1 for the WHOLE request
— `resolve_references needs the presentation compiler` — which `verify-diff.sh` notes. It quotes
that reason, not the JVM warnings printed above it. Generate the metadata with the build's
`scalaSemanticWriteClasspath` task.

## Turn-end purrism rewrites and the memorisation check

Two stages added by spec 2026-09-25, both at turn-end. The rewrite stage EDITS: it applies purrism's
scalafix rewrites to the lines this session's agent changed, then blocks once so the agent reviews
them. The memorisation check only reads: it is the fourth check of `verify-diff.sh` (above), so it
runs at turn-end and, through `--staged`, at the commit boundary too. Every note either stage can
print is in [the NOTE table](#diff-scoped-verification-verify-diffsh) above.

### The rewrite stage

**What it does.** For each module the turn touched whose capabilities include `scalafix`, turn-end
collects the lines this turn changed — `git diff -U0 HEAD` for a tracked file, the whole file for an
untracked one — as `<path> TAB <start> TAB <end>` rows (root-relative, 0-BASED, END-EXCLUSIVE; the
same shape `dsh_diff_ranges` writes), and runs

```sh
./mill --ticker false --color false <module>.fixRanges --rangesFile <ranges.tsv>
```

`--rangesFile` is a NAMED flag: Mill 1.1.8 rejects a positional argument to a `Task.Command`
(`Missing argument: --rangesFile <str>`). `fixRanges` (in `GateLayer`, `kit/recipes/mill/Gate.mill` — copied to a project's `buildKit/Gate.mill`, beside `fixStrict`)
runs the module's scalafix rules and applies ONLY the patches whose every edit falls inside a range; a
patch that reaches outside — the import a rewrite needs, a signature change above the line — is
skipped whole. It prints `fixRanges: applied N`, where **N is a count of PATCHES, not of lines or
files**, and exits 0 only when it read every range and scalafix evaluated and applied every file. A
missing or unreadable ranges file, or a malformed line in it (not three TAB fields, a start or end
that is not an integer), fails the command by name — `fixRanges: malformed ranges line 3: …` —
never `applied 0`. Turn-end does not trust N to decide whether anything changed: it saves each file's
original first and compares bytes afterwards.

Then, per module: if `fixRanges` failed, anything it wrote is restored and the module gets a
`purrism rewrites (not applied)` note. If it changed a file, the module is compiled; a rewrite that
does not compile is undone — every file of that module the rewrite changed gets its original back —
with a `purrism rewrite reverted` note (a partial rewrite whose import was out of range is the usual
cause, and so is a purrism bug where two rewrites on one line do not compose: measured, `def in(value:
Option[Int]): Int = value.getOrElse(0)` widens to `G[_]: Foldable` AND rewrites to `.orEmpty`, which
does not compile). Every module is attempted first; then, if any rewrite survived, the turn BLOCKS
once with the instruction and the unified diff — instruction first, because the message is cut from
the end and may only ever lose diff lines. Measured on skreeep2 (a new file, session baseline
recorded, real purrism):

```
BLOCKED by the DSH gate: purrism rewrote the lines you changed in app.
Confirm the rewritten code still does what you meant, then end the turn again. If a rewrite is wrong,
do NOT merely revert it: the next turn-end reapplies it, and fix --check blocks the original anyway.
Instead restructure that code so the rule no longer matches, with a comment saying why, or
report the rule, the file:line and the reason to the human.
// scalafix:ok does not suppress most purrism rewrites. The rewrites:
@@ -1,5 +1,6 @@
 package com.github.mercurievv.skreeep2.app
 
+import cats.syntax.all._
 object ZZRewriteProbe:
   val seed: Option[Int] = Option(3)
-  val total: Int = seed.getOrElse(0)
+  val total: Int = seed.orEmpty
```

The next turn-end finds nothing left to rewrite on those lines and goes on to the ordinary chain.

**What it does NOT do.**
- It never rewrites a line that is unchanged from HEAD. The ranges it hands purrism are `git diff -U0
  HEAD`, so they cover every line changed this SESSION, not only this turn: earlier turns' lines, and a
  human's mid-session lines in a file that was clean at SessionStart, are rewritten too (see "What is
  protected from a rewrite, and what is NOT" below). Whatever it rewrites, it blocks with the diff
  before the turn can end, so nothing is rewritten unreviewed.
- It never runs at the commit boundary. `verify-diff.sh --staged` has no rewrite stage: rewriting the
  index would change what is being committed.
- It does not replace `fix --check`. The ordinary chain still runs `<module>.fix --check` and
  `fixStrict` over WHOLE files afterwards, so a pending rewrite outside the changed lines blocks
  exactly as it did before this stage existed.

**It runs only under a session baseline.** The stage needs to know which lines are the agent's, and
only the SessionStart baseline (`sh .dsh/engine/gate.sh baseline`, wired to `SessionStart` in
`.dsh/hooks.json` and `.dsh/cc-settings.json`) can say so. With no baseline record, an unreadable one,
or no sha256 tool to compare it with, the stage does not run and says `purrism rewrites skipped` —
the checks fail closed by checking MORE in those modes, but a stage that edits files would fail open
by rewriting someone else's work. It is also skipped at the attempt cap, where turn-end would release
the turn and a rewrite would end it unreviewed.

**What is protected from a rewrite, and what is NOT.** The baseline records, at SessionStart, which
`.scala`/`.sc`/`.mill` files are dirty and a hash of each — a hash per file, never which lines are
whose. From that it can protect exactly one thing:
- **Protected: a file that was already dirty at SessionStart.** It has a baseline row, so its diff
  against HEAD is known to mix the human's earlier lines with the agent's, and the stage never
  rewrites it: `purrism rewrites (not applied) in <module>` names it, and `fix --check` still gates it.
- **NOT protected: a file that was clean at SessionStart and that the human edits DURING the
  session.** It has no baseline row, so every line that differs from HEAD reads as the agent's. If the
  agent touches that file too, the stage rewrites every changed line in it — the human's mid-session
  lines included. The baseline cannot tell those lines apart, because it only knows what the file
  looked like when the session started.

So a human who edits a file in the middle of a session the agent is also working in should commit or
stash that work first, or edit a file the agent will not touch. The rewrite still blocks with the full
diff before the turn can end, so nothing is rewritten unseen — but the diff is shown to the agent,
not to the human.

**Why reverting alone loops, and what to do instead.** Reverting a rewrite by hand does not stop it:
the line is still one that differs from HEAD, so the next turn-end rewrites it again and blocks again,
until the attempt cap releases the turn unverified. And the original line is blocked regardless: the
ordinary chain's whole-file `<module>.fix --check` fails on the same pending rewrite, and its remedy
(`fix`) applies it. So the block message tells the agent to confirm the rewritten code still does what
it meant, and, if a rewrite is wrong, NOT to merely revert it but either to restructure the code so
the rule no longer matches (with a comment saying why) or to report the rule, the file:line and the
reason to the human. It offers no suppression comment, because there is none that works for most
purrism rules. **Measured:** scalafix honours `// scalafix:ok` only for a patch its rule marks
`atomic`, and in scalafix-purrism only `KleisliScope` does. Purrism's `PreferOptionIdioms` rewrite
(`getOrElse(0)` → `orEmpty`) is not — `// scalafix:ok`, `// scalafix:ok PreferOptionIdioms` and a
`// scalafix:off` … `// scalafix:on` block all left it applied, and `fix --check` itself warned
`UnusedScalafixSuppression` and exited 1 on the commented line. Honouring the comment harness-side
cannot work either: the stage could skip the line, but `fix --check` would still block it. Until
purrism marks its rewrites `atomic` (a purrism change), there is no per-line opt-out: a wrong rewrite
that cannot be restructured ends at the attempt cap, released unverified and logged in
`unverified.log`, which is the harness's existing path to the human.

### The memorisation check

A production construct whose literals are largely the visible tests' own inputs and expected outputs
has learned the tests, not the problem. The signal is OVERLAP with the tests' literals, not size: a
MIDI note table and a memorising table look alike by size, and only the second one's keys are the
test inputs.

**The rule** (`dsh_memo_judge`, lib.sh). Literals come from ScalaSemanticMCP's `literal_tokens`, each
with its enclosing definition.
1. **Test values**: every literal of every VISIBLE test source — a `.scala` file under its owning
   module's `test/` directory (the longest module dir in `.dsh/.state/modules.tsv`) and not sealed. The
   holdout is sealed, and the threat is memorising what the agent can see. The set is cached by the
   test files' content in `.dsh/.state/memo-testvals.<key>`; a set missing any file is not cached.
   With no sha256 tool (`shasum`/`sha256sum`) there is no content to key on, so no cache is read or
   written and the set is read fresh every time — a key on the file list alone would judge an edited
   test by its stale literals.
2. **Constructs**: every literal of every changed production `.scala` file, read WHOLE-FILE and
   grouped by its enclosing definition `kind:name:line` (0-based line; `file` for a top-level one).
3. **Only touched constructs are judged** — one with a literal on a line this turn changed — but a
   touched construct is counted WHOLE, so a table grown a few rows per turn is still judged whole.
4. **Trivial literals are dropped**: a number (`int`, `long`, `double`, `float`) whose absolute value
   is at most `trivial_abs`, and any other literal of at most one character.
5. **Count occurrences**: `n` = the construct's remaining literals, `k` = how many of them have a value
   that is also a test value (a repeated value counts each time).
6. **Flag** when `k >= min_overlap` AND `k / n >= min_ratio`. Defaults: `min_overlap 8`,
   `min_ratio 0.5`, `trivial_abs 10`. A flagged construct BLOCKS (a finding, at both boundaries),
   naming the construct, `k of n`, and up to five of the overlapping values. At turn-end the block's
   headline and remedy name the families present: a memorisation-only block says the changed code
   lists the tests' own values and that it clears only by computing them (restructuring the
   construct) or by an allow row the human writes — never "does not exist" or "fix the names", which
   belong to an unresolved-names block; a block with both kinds carries both remedies.

**A worked example**, measured on skreeep2. A planted table whose ten keys are ten string
literals of `app/test/…/SymbolicVsBreezeSpec.scala` (the values `1`–`10` are trivial and dropped):

```
--- construct(s) whose literals are largely the tests' own values ---
  app/src/com/github/mercurievv/skreeep2/app/ZZMemoTable.scala val:answers:3: 10 of 10 literals also appear in the tests — e.g. 400 further launches changed nothing | a batched launch renders every voice, … 
Exempt a legitimate table with an allow row in .dsh/policy/memorisation.tsv (the human's).
```

k = 10 ≥ 8 and 10/10 ≥ 0.5: blocked. The contrast — a note table, `"C4" -> 261.63` through
`"B4" -> 493.88`, twelve names and twelve frequencies — has n = 24, and only `440.0` (A4) also occurs
in the tests: k = 1 < 8, so it passes, with no note. The same shape, judged by what its values
coincide with.

**`.dsh/policy/memorisation.tsv`** sets the thresholds and holds the exemptions — two row shapes,
TAB-separated, `#` comments and blank lines ignored:

```
min_overlap	12
core/src/Notes.scala	val:table:3	the MIDI note table; its keys are the standard note names
```

A `key TAB value` row sets a threshold (`min_overlap`, `min_ratio`, `trivial_abs`; the value a plain
non-negative decimal, and `min_ratio` at most 1), in exactly two fields. A `path TAB construct TAB reason` row exempts one construct, written exactly as
the block names it — and since the construct carries its line, a row goes stale when lines above it
move. A malformed threshold falls back to its default so the check keeps working, and
`check-harness.sh` FAILs on it (below) so that fallback is never silent. A table saved from a CRLF
editor is tolerated: the CR and the blanks around each field are stripped before a value is
validated, so `min_overlap 12` saved with CRLF still reads as 12.

**Why the exemption is human-only.** The table is frozen (`.dsh/frozen-paths`): an agent that could
write an exemption could exempt its own reward hacking, and the check would measure nothing. The
agent proposes an exemption in chat; the human writes the row.

### Installation rules for both stages

`dsh_verify_checks` (run by `check-harness.sh`) adds, beside the diff-scoped rules above:
- **`.dsh/policy/memorisation.tsv` parses** — `ok` with its threshold and exemption counts; `FAIL` for
  any row that is neither a threshold (a key other than `min_overlap`, `min_ratio`, `trivial_abs`, or a
  value that is not a non-negative decimal after CR/blank stripping) nor an exemption (three fields,
  none empty — an exemption with no reason), naming up to three rows as `line N: …` with each TAB shown
  as `<TAB>`. Two rows that look valid are FAILs too, each saying why: a threshold key with a third
  (reason) column — it would read as an exemption for a path named `min_overlap` while the default
  stays in force, and a threshold row takes exactly two fields; and a `min_ratio` above 1, which no
  construct can reach (k/n is at most 1), so it would disable the check — exempt one construct with an
  allow row instead. A CRLF table on its own is a `note`. No table at all is a `note`: the defaults are in
  force and nothing is exempt.
- **it is frozen** — `ok`, else `FAIL`, whether or not the file exists: an agent that could CREATE it
  could exempt itself.
- **the launcher answers `call literal_tokens`** — a one-file request carrying its own `source`
  (`object DshLiteralProbe { val probe = "dsh-literal-probe" }`), which needs neither a file on disk nor
  the presentation compiler. `ok` only when the answer carries the literal `dsh-literal-probe` back; a
  launcher without the tool (`unknown tool: literal_tokens`), an empty, echoing or error answer is a
  `note` quoting the first line it did print (stderr first, `WARNING:` lines skipped, else stdout, else
  `no output at all`); a probe killed at 20 s is a `note` that quotes nothing — it says the launcher did
  not answer within 20 s and was killed, and to check the launcher. Bounded by the same
  `dsh_bounded_probe` as the `resolve_references` probe.

The rewrite stage has no rule of its own; it depends on the SessionStart hook being wired (the
`baseline` entries in `.dsh/hooks.json` and `.dsh/cc-settings.json`) and on `fixRanges` being in the
module's layer trait (by mixing in `GateLayer`). Without the first it says `purrism rewrites skipped` every turn; without the
second `fixRanges` fails by name and every module says `purrism rewrites (not applied)`.

## Vericoding: contracts are the human's, Stainless checks the body

Spec 2026-09-27 (roadmap item 9): the human writes a kernel's `require`/`ensuring`/`decreases`, the agent writes the
body, and [Stainless](https://github.com/epfl-lara/stainless) decides. The agent's side is the `vericoding` skill
(`.dsh/skills/vericoding/SKILL.md`); the build side is `kit/recipes/mill.md` §8 (`StainlessModule`,
`scripts/stainless-verify.sh`, measured in `kit/recipes/mill/stainless-feasibility.md`). The implementation is the
"vericoding" section of `lib.sh`, the snapshot block of `hooks/baseline.sh` and the vericoding stage of
`hooks/turn-end.sh`, whose headers carry the reasoning.

**`.dsh/policy/kernels.tsv`** — the registry, seeded header-only and frozen (`.dsh/policy/kernels.tsv` in the seeded
`frozen-paths`). One row per verified file, TAB-separated, `#` comments and blank lines ignored:

```
core/src/com/example/PureKernels.scala	core	the saturation and time-conversion kernels
```

The path is root-relative, as git reports it: one leading `./` is stripped; an absolute path, a `..` segment or a
second `./` is a check-harness FAIL, because it would never equal a touched path and the stage would silently never
run. check-harness (`dsh_kernel_checks`) also FAILs a row with fewer than three fields, a file that does not exist, a
module not in `.dsh/.state/modules.tsv`, and a registry that is not frozen; with rows present, it also FAILs contract
snapshots that are not frozen (`the contract snapshots (.dsh/.state/contracts/**) are not frozen — add the row to
.dsh/frozen-paths` — a re-vendored project keeps its old frozen-paths) and an existing `scripts/stainless-verify.sh` or
`buildKit/Stainless.mill` that is not frozen (`<file> is not frozen — an agent could disable Stainless; add it to
.dsh/frozen-paths`). With rows present and no FAIL it probes
that the launcher answers `call contract_clauses` (a note, not a FAIL, when it does not — the guard then stands down
at turn-end, named).

**The contract snapshot** — `.dsh/.state/contracts/<session>.tsv`, frozen by the seeded row `.dsh/.state/contracts/**`.
SessionStart (`gate.sh baseline`) ALWAYS writes it on a session's first start: the clauses of every registered kernel
(dirty or not) from ScalaSemanticMCP's `contract_clauses`, one `# file <uri>` line per file the tool read, and one
`# escapes <uri> <n>` line per registered kernel file — its count of non-comment lines naming `assume(`, `@extern` or
`@ignore` (needs no launcher, so an `incomplete:` record carries it too); header-only
when nothing is registered; `# DSH contract snapshot <sid> <date> incomplete: <reason>` with no rows when the tool
failed. It never blocks SessionStart. A later SessionStart of the same session (resume, compact) keeps the record, and
does NOT retake a missing one: that would adopt the session's own contract edits as the human's. The flip side is the
one rule the human must keep: **a new session snapshots the current tree's contracts as the human's**, so before
starting a new session after an agent session, review `git diff` of the kernel files for contract changes.

**The turn-end stage.** It runs last — after the per-module checks and after turnEndTests — only for a module owning a
kernel this turn touched, and not for a module whose checks or turnEndTests already blocked (said, by name). For each such module: the contract guard on the touched
kernels — a clause whose `shape` (a hash of its syntax tree, so reformatting is not a change) changed, or a removed
clause, or a clause added to a def the snapshot has (a new `requires`, `ensuring` or `decreases`, or a `requires`
appended after the existing ones — adding a precondition is how a counterexample is made to vanish), blocks, and
Stainless is not run for that module; a new def with a contract (a lemma) is allowed. Then
`./mill --no-server --ticker false --color false <m>.stainlessVerify --targets <every kernel of m, kernels.tsv order>`,
because a body change can break a lemma another kernel relies on. `--no-server` is the measured mode: through a Mill
daemon the cap's kill would end only the client, and Stainless would keep running in the daemon. The verdict comes from the script's marker lines
(`stainless-verify: OK —` / `FAILED —` / `SETUP —`; `dsh_stainless_verdict`), not Mill's exit, which is 1 for both
script exits 1 and 2. Every headline, verbatim (`<m>` the module):

| Condition | Class | Headline |
|---|---|---|
| a registered kernel file no longer exists (checked every turn that reaches the gate) | block | `vericoding: registered kernel missing` |
| a touched kernel's clause changed shape, a clause/def-with-contract was removed, or a clause was added to a def the snapshot has | block | `vericoding: contracts changed in <m>` — rows `<uri> <key> <kind>: was <old>; now <new>` / `… removed (was <old>)` / `… added (<text>)` |
| a touched kernel has more non-comment lines naming `assume(`, `@extern` or `@ignore` than its `# escapes` count at SessionStart | block | `vericoding: <m> — verification escape added in <file>` — the counted lines, then `assume/@extern/@ignore turn verification off; remove it, or ask the human`; Stainless is not run for that module |
| no snapshot file for this session (deleted, or the session started under an older engine) | block | `vericoding: contract snapshot missing` — the human reviews `git diff -- <files>` before a new session |
| Stainless found an `invalid` VC (script exit 1) | block | `vericoding: <m> — Stainless found invalid verification conditions` — each VC, its counterexample, colour stripped and bounded |
| a `???` on a non-`//` line of a touched kernel, or Stainless's `missing implementations` marker (a typed `(??? : T)` exits 0) | block | `vericoding: <m> — a kernel body is not implemented yet` |
| Stainless's own compile/extraction error names a target (the body left the supported subset) | block | `vericoding: <m> — Stainless cannot compile <file>:<line>` |
| `unknown` VCs (solver timeout) | note | `vericoding: <m> — <N> verification condition(s) unknown (solver timeout)` — the human decides whether to accept them |
| the snapshot is `incomplete:` or does not cover a touched kernel | note | `vericoding: no contract snapshot for <files>` — Stainless still runs |
| launcher missing, call failed, a file unread, no JSON reader, answer not JSON | stand-down | `vericoding: contract guard stood down` — Stainless still runs |
| the snapshot has no `# escapes` count for a touched kernel (a record from an older engine) | note | `vericoding: escape markers not compared for <files>` — Stainless still runs |
| a clause with neither shape nor text on either side | stand-down | `vericoding: contract guard cannot compare <key>…` |
| script `SETUP —`, no marker, or `OK` with a failed Mill | stand-down | `vericoding: Stainless could not run for <m>` — not a verdict on the body |
| the run outlived its cap | stand-down | `vericoding: Stainless did not finish for <m> within <N> s — not verified` |
| 10 s or less left of the Stop budget when the module's turn came | stand-down | `vericoding: no time left to run Stainless for <m> (the Stop hook's budget) — not verified` |
| the module's own checks or its turnEndTests blocked this turn | stand-down | `vericoding: Stainless not run for <m>` |

The notes and stand-downs are printed on allow AND on block (they ride `vk_note`, like the rewrite stage's notes);
they are not F53 notes. A successful run adds `<m>.stainlessVerify` to the `Ran, in this order:` line.

**One time budget.** The stage shares the Stop hook's budget and runs last, so Stainless gets only what the checks and
turnEndTests left: each module's run is capped at `min(DSH_STAINLESS_CAP, what is left of DSH_STOP_BUDGET since the
hook started)` — defaults 480 s and 540 s, under the hook's 600 s timeout — and is not started at all with 10 s or
less left. The cap kills the whole process tree. turnEndTests itself is not capped: a suite that outlives the hook's
timeout ends the turn with no verdict, vericoding or not.

**Dependencies.** ScalaSemanticMCP's `contract_clauses` (one-shot `scalasemantic-mcp call contract_clauses '<json>'
<root>`, syntax-only, no classpath; install with `./mill installLocal` in ScalaSemanticMCP) — without it the guard
stands down every turn and SessionStart records an `incomplete:` snapshot; and the module's `StainlessModule` wiring
(recipe §8), which downloads standalone Stainless 0.9.9.3 on first use (`curl`, `unzip`). Git-ignore
`.stainless-cache/` in the project.

**Limits, from the tool and from measurement.** Stainless verifies only its supported subset of Scala (pure code, no
mutable state or unrestricted effects); anything else is a `cannot compile` block. `==>` binds like `==`: a contract
must bracket implications (`a ==> (r == c)`). Preconditions are proved at call sites, not assumed from callers.
Nonlinear arithmetic can time out, and a timeout is `unknown`, a note — measured: the multiplication-overflow checks of
the pilot's `Long` conversions stayed `unknown` at 10 s and at 60 s per VC. A typed `(??? : T)`
body is reported as a missing implementation and exits 0, which is why the stage blocks on the marker and on a
`???` in the source instead of trusting the exit.

**What it cannot see.** The guard compares clauses, not meaning: a body that makes a contract vacuous by a construct
outside the clauses (a shadowing local `require`) is the skill's rule and the reviewer's, not the gate's. A def with no clause at all is not in `contract_clauses`'
answer, so one gaining its first `require` reads as a new def (a lemma), not as an added clause. The escape count
matches spellings: `assume (x)` with a space, an aliased import, or another way to tell Stainless to skip a def is not
counted. Removing the `StainlessModule` mixin from `build.mill` (so `stainlessVerify` no longer resolves — a `could
not run` note) is the engine-wide `build.mill` exposure, not closed here: `build.mill` is not frozen. Bash `rm`
of a frozen path is not denied by the frozen-path layer; the snapshot's deletion is caught instead by the
`contract snapshot missing` block.

## Running the engine's checks

In the template (the only place the engine changes):

```sh
sh kit/harness/tests/run.sh                  # the behavioural suite: one fixture case per gate decision
dash kit/harness/tests/run.sh                # the same cases with gate.sh and every hook under dash
sh kit/harness/tests/lib-test.sh             # lib.sh helpers, the JSON readers, the shared report plumbing
sh kit/harness/tests/install-test.sh         # install.sh, STAMP, seeds, drift (template-only: never vendored)
sh kit/harness/tests/feedback-test.sh        # the feedback wrapper: stages, log path, DIAGNOSTIC/INSTRUCTION rendering
sh kit/harness/tests/instructions-test.sh    # instructions-sync.sh: the one writer of the vendored purrism table
sh kit/harness/tests/module-map-test.sh      # which Mill module owns a path, and the cached map
sh kit/harness/tests/health-test.sh          # the health probe's verdict and its lines (the non-Mill notes are run.sh cases)
sh kit/harness/tests/vocabulary-test.sh      # payload shapes: both dialects' tool names and field spellings
sh kit/harness/tests/frozen-mutations.sh     # every frozen-path rule removed on a copy — its fixtures must go red
sh kit/harness/tests/smoke-second-project.sh # machine-specific end-to-end smoke (template-only: never vendored)
```

In a project, the same suites — all but the two template-only ones, `install-test.sh` and
`smoke-second-project.sh` — run from the vendored copy under `.dsh/engine/tests/`, and
`sh .dsh/engine/check-harness.sh --project .` runs them together with the project's own suites (`.dsh/tests/`,
e.g. `wiring-test.sh`, and `committed-tree-test.sh` under `--full`). Its groups: **A** the profile is materialized
and composes; **B** `hooks.json` parses, names this gate and dispatches every subcommand it wires; **C** the
semantic guard's preconditions and the frozen-path list; **D** test integrity — every fixture tracked, no fixture
depending on a directory a clone would not have, every `*-test.sh` suite and `run.sh` green; **E** the cwd binding;
**F** every skill under `.dsh/skills/` has a loadable name; **G** the vendored engine against its `STAMP`
([Drift](#drift)). A build artifact or per-session cache the checkout cannot be expected to have yet is a note; a
file the repository commits being absent, unreadable or wrong is a FAIL.

Mill is invoked in non-writing form (`moduleMap`, `checkFormat`, `fix --check`, `fixStrict`, `compile`) with ONE
exception: turn-end's rewrite stage runs `<module>.fixRanges`, which writes only the patches inside the lines this
session's agent changed, and then blocks so the agent reviews the diff. No hook ever runs `preCommit`, `reformat` or
a bare `fix`.
