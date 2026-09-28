---
name: vericoding
description: Use when a task touches a file listed in .dsh/policy/kernels.tsv, or asks to implement a function whose require/ensuring is already written — fill the body until Stainless accepts it, never the contract.
---

# Vericoding

The human writes the contract — `require`, `ensuring`, `decreases`. You write the body, and
[Stainless](https://github.com/epfl-lara/stainless) decides whether the body meets the contract. A body is done
when Stainless proves it, not when it compiles or when the tests pass.

## When

- The task touches a file listed in `.dsh/policy/kernels.tsv` (`<file> TAB <module> TAB <reason>`, root-relative
  paths). The registry is the human's and is frozen: you may read it, never write it.
- The task asks you to implement a function whose `require`/`ensuring` is already written. That includes a body
  that is still a `(??? : T)` hole.

The turn-end gate verifies every registered kernel of a module whenever a turn touches one of them. So this loop
runs whether you start it or not. Run it yourself first, because the gate's version costs a blocked turn.

## The loop

1. **Read the contracts.** Call `contract_clauses` on the kernel file (the ScalaSemantic tool, or
   `scalasemantic-mcp call contract_clauses '{"files":[{"uri":"core/src/K.scala"}]}' .`). Each def comes back
   with its `require`s, its `ensuring` and its `decreases`, as source text. That is the specification. Read it
   before the body. `==>` binds like `==`, so `a ==> r == c` means `(a ==> r) == c`. Read a contract the way
   Stainless parses it.
2. **Fill one body at a time.** Leave the others as typed holes, `(??? : T)`. An untyped `{ …; ??? }` does not
   compile. For a hole, ask `hole_context` for the expected type and the names in scope, then write the body. Keep
   it in the Stainless-supported subset of Scala: pure, with no mutation, no unrestricted effects, and no library
   call Stainless cannot extract. A body Stainless cannot compile blocks the turn just like a wrong one.
3. **Verify.** Run `./mill <module>.stainlessVerify --targets <file>,<file>` with every kernel file of the module
   from `kernels.tsv`, comma-separated. `--targets` is a named argument, because Mill rejects positional command
   arguments. The script prints one marker line:
   - `stainless-verify: OK —` means no invalid verification condition.
   - `stainless-verify: FAILED —` means at least one invalid condition, with a counterexample.
   - `stainless-verify: SETUP —` means the tool did not run. This is not a verdict on your body.
   - `OK` is not enough if a hole is left. Stainless accepts a typed `(??? : T)` as a missing implementation, so
     it still exits 0, and the gate blocks it.
4. **Read each invalid VC and its counterexample.** Every VC names a kind (`postcondition`, `precondition`,
   `body assertion: Multiplication overflow`, …), a position, and the input values that break it. Change the
   body so that the input no longer breaks it, then go back to step 3. The counterexample is a concrete input.
   Trace the body on it before you change anything.
5. **Handle `unknown` VCs.** An `unknown` VC is a solver timeout: the solver neither proved nor refuted it.
   Simplify the body, for example by splitting a nonlinear expression, adding an intermediate `val`, or ordering
   a guard so the check becomes linear. If that does not help, report it and ask the human. The gate only notes
   an `unknown` VC, and the human decides whether to accept it. **Never add `assume`, `@extern` or `@ignore`.**
   `assume` makes the solver take the claim as true, which is exactly what is being checked; `@extern` and
   `@ignore` make Stainless skip the body. The gate counts them and blocks a kernel that gained one.

## Never

- Edit, weaken, delete or move a `require`, `ensuring` or `decreases`, not even to reformat one onto another
  line in a way that changes its term. The gate compares each clause with the snapshot taken at session start
  and blocks any change or removal.
- Add a `require`, `ensuring` or `decreases` to a def that already has a contract. A new precondition makes a
  counterexample vanish instead of fixing the body, and the gate blocks it as an added clause.
- Unregister a kernel, rename or delete a kernel file, or edit `.dsh/policy/kernels.tsv`.
- Add a local `require` or `ensuring` def, or anything else that shadows Stainless's own, to make a clause
  vacuous.
- Touch `.dsh/.state/contracts/`. The snapshot is the human's record, and it is frozen.
- Edit `scripts/stainless-verify.sh`, `buildKit/Stainless.mill`, or the `StainlessModule` mixin in `build.mill`.
  The wiring is the human's.

A **new** def with its own contract, such as a lemma or a helper, is allowed. Only the existing clauses are the
human's.

## When the contract looks wrong

Sometimes the counterexample is an input the contract should have excluded, or an output the contract should
have allowed. For example: a `NaN`, an overflow the `require` does not rule out, or a bound that is off by one.
When that happens, **stop**. Quote the VC and its counterexample in chat, say which clause you believe is wrong
and why, and ask the human. Do not weaken the clause yourself, and do not bend the body to satisfy a contract
you think is wrong. Only the human decides whether the contract changes.

## What the gate does

At turn-end, for each module whose kernel the turn touched, the gate runs only after that module's own checks
and its turnEndTests pass. It first runs the contract guard against the session's snapshot, then Stainless over all the module's
kernels. The headlines are quoted verbatim below, with `<m>` for the module.

These headlines **block** the turn:

- `vericoding: registered kernel missing`: `<path> is listed in .dsh/policy/kernels.tsv but does not exist —
  restore it; only the human changes the registry`
- `vericoding: contracts changed in <m>`: rows `<uri> <key> <kind>: was <old>; now <new>`,
  `… removed (was <old>)` or `… added (<text>)`, then `contracts are the human's — ask in chat before changing a
  require/ensuring/decreases; restore the original clause`
- `vericoding: contract snapshot missing`: the snapshot `.dsh/.state/contracts/<session>.tsv` is gone. Do not
  recreate it. Stop and ask the human to review `git diff` of the kernel files.
- `vericoding: <m> — Stainless found invalid verification conditions`: `INVALID <file>:<l>:<c>: '<vc kind>' VC
  for <fn>` plus the counterexample, then `fix the body so the contract holds; if the contract itself is wrong,
  stop and ask the human.`
- `vericoding: <m> — a kernel body is not implemented yet`: `a kernel body is not implemented yet: fill it
  (vericoding skill)`. This fires on a `???` left in a touched kernel, or on Stainless's `missing
  implementations` marker.
- `vericoding: <m> — Stainless cannot compile <file>:<line>`: `the body must be in the Stainless-supported
  subset of Scala; fix it, or ask the human`
- `vericoding: <m> — verification escape added in <file>`: the lines naming `assume(`, `@extern` or `@ignore`,
  then `assume/@extern/@ignore turn verification off; remove it, or ask the human`

These headlines are **notes**. They do not block, and each one says what was not checked:

- `vericoding: <m> — <N> verification condition(s) unknown (solver timeout)`: the human decides whether to
  accept these.
- `vericoding: Stainless could not run for <m>`: a setup failure, not a verdict on the body.
- `vericoding: Stainless did not finish for <m> within <N> s — not verified`, and `vericoding: no time left to
  run Stainless for <m> (the Stop hook's budget) — not verified`: the stage has one time budget per turn
  (`DSH_STAINLESS_CAP`, 480 s; `DSH_STOP_BUDGET`, 540 s). Run the verification by hand.
- `vericoding: no contract snapshot for <files>`: the snapshot was recorded `incomplete:`, or it does not
  cover the file, so its contracts could not be compared. Stainless still runs.
- `vericoding: escape markers not compared for <files>`: the snapshot has no escape count for the file (an older
  record), so an added `assume`/`@extern`/`@ignore` is not detected. Stainless still runs.
- `vericoding: contract guard stood down`, and `vericoding: contract guard cannot compare <key>`: the guard
  could not read the contracts. Stainless still runs.
- `vericoding: Stainless not run for <m>`: the module's compile, checks or turnEndTests already blocked. Fix
  those first.

**The snapshot is taken per session.** SessionStart snapshots the contracts of every registered kernel as the
human's. A **new** session therefore adopts whatever the tree holds at that moment, including any contract
change an earlier agent session left behind. Before the human starts a new session after an agent session, they
review `git diff` of the kernel files for contract changes. If you see the `contract snapshot missing` block,
say exactly that to the human.
