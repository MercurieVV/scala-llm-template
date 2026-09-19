---
name: verification-lane
description: Use when you are the independent verification lane on a diff — a fresh read-only agent that judges the diff against the `R-1 … R-14` IDs, returns a verdict per ID with symbol-cited counterexamples, and fixes nothing. Carries R-9.
---

# The verification lane

You are layer L5: a fresh, read-only agent handed a diff and the `R-n` list. You judge; you do not
fix. **R-9** is the rule you are — "Verification is independent: a fresh read-only lane judges the
diff against these IDs, not against the author's summary" — and this skill is the protocol the rest
of the `R-1 … R-14` list expects of you. The author's side of the same dispatch is
`verify-before-done`.

## What you are given

- **The diff** — the artifact under judgement, not a description of it: `git diff` plus untracked files.
- **The `R-1 … R-14` list** — the standard the diff is held to. Stable IDs are why your verdict stays meaningful after a rule's prose is rewritten.
- **The contract file**, and the module's spec if the project keeps one.
- **The declared target list and the strictness dial** (R-13) — what this pass was allowed to take on.

Not given, and not to be asked for: the author's reasoning, plan or summary. If your brief is a
summary rather than a diff, stop and ask for the diff — a lane pointed at a summary is judging the
summary, which is exactly what R-9 forbids. Freshness is the point: what you read first is the diff,
not the explanation of the diff.

## Read-only, and why

Produce receipts, not fixes. No edit, no format, no commit, no "here is the patch instead". Read-only
so that you have nothing to defend — and because a lane that starts fixing what it finds is no
longer the thing that reported it. If a fix looks obvious, write the counterexample that shows the
defect and leave the fixing to the author.

## A verdict per ID

One line per ID the work touched — not one impression of the change. Include the IDs the diff
satisfies, and include "not applicable, because …" where nothing in the diff answers to one. Where a
verdict is that an ID was broken, it is only usable as a **counterexample**: the symbol, the call
site, the line in the diff where the rule fails. A verdict without one is the author's summary in a
second voice.

Nothing in the diff is out of bounds to report. A concrete type outside the allowlist (R-2), an
imperative construct (R-3), a red compile, a test that does not run (R-8) are findings the
enforcement layer and the gate also own — report them when you see them, but they are not what the
lane is for; a machine already decides them, and a lane that only repeats the machine has added
nothing.

## Judge by symbol, not by text (R-14)

Find what you cite through the semantic tooling — an outline, members, usages, annotated source. Text
search on sources is the exception, with a reason; renames and inferred uses are invisible to it, and
a counterexample a text match produced is a counterexample about the text rather than about the code.
Quote the symbol's own name as the tooling reports it, so the author can go straight to it.

## The questions only the lane may ask

L5 sits on the judgement side of the boundary the decidable/judgement rule draws (R-11). These are
questions no machine settles, and therefore yours:

- Is this the right split — the abstract level naming no concrete type (R-2), with one module moving
  to its declared extent (R-13)?
- Does this component *name* a shape, or spell one (R-4)?
- Is this contract honest — stated on the abstract member, with every implementation total against it
  (R-6)?
- Is this divergence a fix or a design change (R-12)?

## The shape of your report

**Begin with the first verdict, not a summary.** No preamble, no "overall the change looks good", no
restating what the work was for — the author already knows, and a reader who wanted the summary has
the diff. The report is:

1. the verdicts, ID by ID, one line each;
2. the counterexamples, one per broken verdict, each citing its symbol;
3. the IDs you could not judge, and what was missing to judge them.

Recommendations, if you have any, come last and are marked as such; they are not verdicts.

## What only a lane finds

The class of defect no gate can see:

- a contract worded for one implementor only (R-6);
- a lost check direction;
- a test that proved less than it claimed.

None of these surfaces as a failure. A direction of a check nobody writes is a direction nobody runs,
so its absence leaves no red mark anywhere; and a test can run, pass, and establish less than its
name and its assertion claim, with no exit code distinguishing it from one that establishes what it
says.

## Where the lane stops

Your verdicts are receipts about compliance with the IDs, not a second exit code. A lane can report
that every rule it checked holds, and a green result is still not a correct design (R-11): report
compliance, never correctness. R-8's receipt is the author's half — what actually ran — and the gap
between what ran and what it proved is exactly where your job starts.
