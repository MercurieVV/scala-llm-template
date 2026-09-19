---
name: reshaping-module-by-linters
description: Use when reshaping or fixing a module based on scalafix/wartremover/scalastyle (or any linter) findings — before writing any suppression, exclusion, config change, or file/type restructuring in response to a lint finding. Carries R-10 and R-11.
---

# Reshaping Module By Linters

**R-10**: "A finding that cannot be fixed honestly is escalated, never suppressed — no
`@SuppressWarnings`, no allowlist widening, no threshold bump." **R-11**: "State the
decidable/judgement boundary, and never let a machine-decidable rule stand in for a design
judgement." Both are stated in full in the `R-1 … R-14` list your project's kit digest points at,
and cited here by ID; this skill is how they are obeyed at the moment a linter is red.

## Overview

Fix the code the linter flagged. Never make the linter stop looking instead.

**Baseline-tested failure:** under a hard deadline with "don't wait on me, just make it green," an agent without this skill suppressed 8 of 10 real findings (`@SuppressWarnings`, `scalastyle:off`) with TODO tickets, reasoning suppression was "scoped, visible, reversible." It is still ignoring the finding. The user said: never touch rules, configs, or suppress/ignore findings — if a real fix is genuinely unavoidable to skip, **ask**, don't suppress.

## The Rule

**Never** write `@SuppressWarnings`, `// scalafix:ok`, `// scalastyle:off`/`on`, edit `.scalafix.conf` / `wartremoverExcluded` / `scalastyle-config.xml`, bump a threshold, or add any exclude filter — for any finding, under any deadline, at any scope (single line or whole file). No exceptions, no "just this once," no "I'll file a ticket instead." Those are R-10's three named suppressions — `@SuppressWarnings`, allowlist widening, threshold bump — plus the config forms of the same move wearing the tool's own name.

If a finding cannot be fixed safely right now, **stop and ask the user** what to do. Asking is the only acceptable way to defer a finding. Silence-via-suppression is not a substitute for asking, even when the user says "don't wait on me" — that governs pace, not permission to hide a rule violation.

An escalation is not a refusal of the work; it hands the decision to whoever owns the design with the trade-off made legible. Three facts make the question answerable rather than a vote (R-10, R-11):

- **The finding** — what the tool reported and under which rule: the artifact, the place, and the rule's own words, not a summary of the inconvenience.
- **The rule** — the `R-n` ID it violates, and the layer that owns it; a rule changes by adding or superseding an ID, not by quietly editing prose that machinery believes it implements.
- **The cost of each option** — reshaping the code until it satisfies the rule; changing the contract, if the rule is what is wrong; or accepting the divergence and writing it into the record as a ruling (R-12).

The one item that is not an option is a change that makes the finding stop without making it false.

## Rationalization Table

| Excuse | Reality |
|---|---|
| "Deadline in N minutes, ship it" | Suppression is a hidden rule change, not a fix. Ask instead — a blocked item beats a silently disabled check (R-10). |
| "It's scoped to one line/method, not the whole build" | Scope doesn't matter. Any off/exclude/suppress annotation is still ignoring that finding. |
| "I'll leave a TODO + ticket for follow-up" | A TODO is a promise, not a fix. The finding is unfixed right now and the gate is lying about it. |
| "Config threshold bump is safer than an annotation" | Same category, and R-10 names it: both make the linter stop looking. Forbidden equally. |
| "User said don't wait on me / can't answer questions" | That's about pace, not about consent to suppress. Ask anyway, or leave the gate red and say why. |
| "This one's clearly a false positive" | Then read the rule's own source to find out what it actually decides, and say so to the user — ask to change the rule deliberately rather than working around it inline (R-11). |
| "The gate is green apart from this lint finding, so the design is fine" | The finding is machine-decidable; the design is not. A green gate is evidence about the artifact, never a judgement on it (R-11). |

## Triage Order (for the findings you WILL fix)

Batch by risk, re-run the linter once per batch, not once per finding — findings in different files rarely interact.

1. **Mechanical/autofix** — tool has a `--fix`/autofix mode, or the change is pure syntax (add inferred type, add parens). Apply, compile, commit.
2. **Direct fix, no design change** — e.g. `Throw` → `Either`, `isInstanceOf` → pattern match, unit a discarded expression. Check call sites if a signature changes. Fix, compile, commit.
3. **Structural signal** — file-size limit, cyclomatic complexity, non-tail recursion that isn't `@tailrec`-able. These mean split a file, extract a type, or introduce an ADT — a real design change, possibly crossing a module/public-API boundary, and therefore a judgement rather than a lint result (R-11). **Confirm with the user before doing this one**, even under time pressure: state what you'd split/extract and why, and either get a quick yes or leave it red with a clear note of what's blocked and why.
4. **No safe fix found** — stop, ask (R-10). Never resolve this by suppressing.

## Red Flags — STOP

- About to type `@SuppressWarnings`, `scalafix:ok`, `scalastyle:off`.
- About to open `.scalafix.conf`, `wartremover.excludeFilters` in `build.sbt`, or `scalastyle-config.xml`.
- About to bump a numeric threshold (line limit, complexity limit) instead of reducing the metric.
- Thinking "I'll ask forgiveness with a follow-up ticket."
- Thinking a green gate has settled a design question (R-11).

All of these mean: don't write that line. Ask the user instead.
