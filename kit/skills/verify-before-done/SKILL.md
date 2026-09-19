---
name: verify-before-done
description: Use before claiming any task complete, and whenever a diff touches a module's abstract level — requires the gate's own output plus an independent verification lane before "done" is a claim you are allowed to make. Carries R-8 and R-9.
---

# Verify before done

"Done" is a claim with evidence, not a summary of intentions.

**R-8**: "No completion claim without the gate's own output, and the gate must *run* tests, not only
compile them." **R-9**: "Verification is independent: a fresh read-only lane judges the diff against
these IDs, not against the author's summary." Both are stated in full in the `R-1 … R-14` list your
project's kit digest points at, and cited here by ID. Neither half substitutes for the other: the
receipt says the project's own checks were run, and the lane says whether what they checked was what
the rules required.

## The receipt

Before saying a task is complete, paste the command and its result:

```
<the project's preCommit task>    -> clean   (or: the exact failure, quoted)
<the project's prePush task>      -> clean   (before a push; this is where tests run)
```

`preCommit`, `prePush` and `checkFormat` are the names the build contract fixes; how your build tool
spells them is the project's answer, not this skill's. Whose output counts is the part that does not
bend: not a memory of a green run, not a summary written after the fact, not your confidence that
nothing else touched the module.

The turn-end hook (`sh .dsh/gate.sh turn-end`, which the hook runner invokes with its JSON payload on
stdin) blocks a dirty turn, but it proves only what it runs. If it formats, lints and compiles
without running tests, it has said nothing about whether the tests ran — and a check that does not
run leaves nothing for a reader to notice. Nor can it see whether the design still satisfies the IDs
the work was judged against. That needs the lane.

State the ground your receipt stands on, so it is not read as more than it is:

- A red baseline that predates your diff is quoted and attributed, never presented as a filtered
  green gate. Run the declared tasks and show what they actually said.
- An `R-n` ID with nothing wired to point at — no contract file, no spec for a test to discharge —
  is judged unwired and said so, rather than argued from a document that does not exist.
- The declared target list and the strictness dial bind (R-13): a reshape outside the list is a
  finding, however good it looks.

## The independent lane

Dispatch a fresh read-only subagent with **only** what a stranger would have:

- the diff (`git diff` plus untracked files),
- the `R-1 … R-14` list,
- the contract file, and the module's spec if one exists,
- the declared target list and the strictness dial.

Do **not** include your reasoning, your plan, or your summary — those are what the lane exists to
check independently. Ask for a verdict per ID the work touched, including the ones it satisfied, and
for concrete counterexamples, each citing a symbol it found through the semantic tooling (R-14: text
search on sources is the exception, with a reason). A lane that returns "looks good" without symbols
is not a verification.

The protocol the lane itself follows is `verification-lane`; hand it the brief above and nothing else.
A lane that reports every ID holds has said the diff complies with them — it has not said the design
is right (R-11).

## Refusals

Never claim green from a check you did not run; never widen a linter's allowlist or edit a rule's
configuration to silence a finding (R-10); never let a machine-decidable pass stand in for a design
judgement (R-11). If a rule seems wrong, say so and ask.
