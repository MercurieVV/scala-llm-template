---
name: shaping-a-module
description: Use when reshaping or narrowing a module toward the two-level shape (arhitecture = arrows + abstract types, details = concrete instantiation) — before deciding the split, before moving types, and before claiming the reshape done. Carries R-2 and R-4.
---

# Shaping a module

Two of the `R-1 … R-14` IDs are this skill's own: **R-2** — "The abstract level names no concrete
type; it reaches outside its package only through an explicit allowlist" — and **R-4** — "A
component *names* a shape; it does not spell one." Both are quoted here so the skill reads on its own,
but they are not this skill's to restate: the rule list your project's kit digest points at is the
authority, and a rule changes by adding or superseding an ID there, never by silently editing prose
that machinery believes it implements.

Read the project's ground before the module: the target list R-13 requires (a reshape is declared
deliberate by an explicit target list, not by whatever a diff happened to touch), the contract file,
and the gate's baseline — what it says today, red or noisy. The list binds: no regression, new code
conforms, and only the listed modules are reshaped.

**Check `.dsh/frozen-paths` before touching a module**: a frozen path is the human's in-flight
work, no agent writes, moves, reverts or fixes one — every write route the gate sees is denied (the
write/edit tools, a bash write, the annotated buffer, the operand commands `rm`/`mv`/`git checkout|restore`/
`truncate`/`patch`/`perl -i`/`find -delete`, and, while a freeze exists, the whole-tree commands
`git checkout -- .`/`git restore .`/`git clean`/`git stash`/`git reset --hard`), with the reason
quoted — while reading it stays allowed, so a frozen module is surveyed, not edited.

State your project's ground, so this skill is not read as a claim about a finished tree:

- Which modules already carry the two-level split, and which do not compile today. A reshape on a
  red module is finishing work in progress, not a refactor of a green one — say so instead of
  reporting the red compile as a regression.
- Which of the `R-n` IDs have anything wired to point at in this project. A rule with nothing behind
  it — no stated contract, no spec for a test to discharge — has no argument to make; the IDs and
  the code do.

## Procedure

1. **Survey through the semantic tooling, never text search** (R-14: code is read and searched
   symbol-level, not textually; text search on sources is the exception, with a reason). Use an
   outline for the file's shape, members for what a type exposes, usages for who composes it, and
   annotated source for inferred types and implicits — and give the reason when a text search is
   genuinely the only way. Renames and inferred uses are invisible to text, which is why the
   harness's semantic guard denies it in the first place: `grep`/`cat` on `.scala` is stopped by
   `sh .dsh/gate.sh semantic-guard`, with its payload on stdin.
2. **Name the purpose in one sentence.** If it takes two, the module is doing two jobs and the
   split comes before the reshape.
3. **Decide the split.** Abstract level: arrows, abstract type members, and the laws. Implementation
   level: the concrete instantiation, the concrete types, the real work. Composition happens only at
   the abstract level. R-2 is the test the split has to pass: no concrete type at the abstract level,
   and nothing outside the package except what the allowlist grants.
4. **Extrude outward, downward — never upward.** A concrete detail the contract does not need moves
   to the implementation level; an implementation-only concern never appears in the abstract level's
   signatures. Where a signature needs concrete type members, name that shape once in a child trait
   and have the consumer name the trait (R-4) — an inline refinement at the use site is the thing
   R-4 forbids.
5. **Extend the allowlist deliberately.** The enforcement layer's `AllowedShape` rule gains exactly
   what the contract needs. Its schema, the symbol-prefix semantics of `allowedTypes` and the
   own-package-prefix convention are stated once in the README that ships with the rule
   (`arhitecture-shape/README.md`) — read it there rather than from a copy (R-12: a second copy is
   what drifts out of step with the code). A nested module restates its real package prefix in that
   list rather than trusting one derived from the build's module path. Never widen the allowlist to
   make a diagnostic disappear (R-10).
6. **Run the gate.** The project's declared tasks — `preCommit`, `prePush`, `checkFormat` — plus the
   shape rule's own check over the module (the kit's recipe for your build tool names the command:
   `fix --check` under Mill, `scalafix --check` under sbt). Fix what it reports; never widen an
   allowlist or suppress a rule to pass — that is the one move this skill exists to prevent (R-10).
   Finish with the project's `preCommit` and quote its output (R-8).
7. **Verify independently.** Dispatch the verification lane (`verify-before-done` for the dispatch,
   `verification-lane` for the protocol) on the diff before calling the reshape finished. Its brief
   gets the diff, the `R-n` list, the contract file and the target list — never your reasoning
   (R-9).

## What a completed reshape looks like

- The abstract level compiles with no concrete type outside its allowlist (R-2) and no disallowed construct
  (R-3).
- The implementation level holds the concrete choice.
- A shape a signature needs is named once and reused, not spelled at the use site (R-4).
- A nested module's allowlist restates its real package prefix.
- The project's `preCommit` is green with its output quoted, and the tests it runs actually ran
  (R-8).
- The module's purpose is still one sentence.
- One module moved, and it was on the declared target list (R-13).
- An independent lane has returned a verdict per `R-n` ID, citing symbols rather than praise (R-9).
