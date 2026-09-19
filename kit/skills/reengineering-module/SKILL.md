---
name: reengineering-module
description: Use when reengineering or rearchitecting one module at a time in a multi-module codebase — deciding whether to touch a module already marked reengineered/source-of-truth, whether to include not-yet-reshaped dependent modules in build and tests, or what order to fix compilation vs tests in. Carries R-13.
---

# Reengineering Module

**R-13**: "One module at a time, and a reshape is declared deliberate by an explicit target list
rather than by whatever a diff happened to touch." That is the rule this skill exists to hold while
a migration is in flight — the rest of the `R-1 … R-14` list is stated in the rule list your
project's kit digest points at, and cited here by ID.

## Overview

Multi-module reengineering proceeds one module at a time. Modules already reengineered are
frozen source of truth. Modules not yet reengineered are optional reference only. Mixing these
up — editing a frozen module, or dragging an unreshaped module into the build — corrupts the
migration.

The module is the unit because a reshape moves an interface: a module whose abstract level changes is
read differently by everything that depends on it, and a pass that takes two modules at once produces
a diff in which neither move can be judged on its own. That is R-13's reason, not a preference about
tidiness.

## Roles (fill in per task)

Name these three from the project's target list before anything moves. The list is a first-step
output that a human approves — never a scope read back off the diff (R-13):

- **FIXED_MODULES** — already reengineered. Source of truth. Read-only.
- **REENGINEERING_MODULE** — the one module this session changes. One, not two.
- **DEPENDENT_MODULES** — everything else that depends on REENGINEERING_MODULE. Not yet
  reshaped; will get their own reengineering session later.

## Rules

1. **Never edit FIXED_MODULES.** If a change there genuinely seems required, stop, explain why
   in one message, and get explicit permission before touching it.
2. **Exclude DEPENDENT_MODULES from compilation and test runs** for the duration of this work
   (disable in the build, don't delete). Treat their code as background knowledge only — useful
   for understanding intent, never a constraint on the new design. This is a scope decision on the
   declared target list (R-13), and it is written into the record (R-12) — it is never a route for
   making a finding in the module being reshaped disappear (R-10).
3. **Fix REENGINEERING_MODULE in this order, and don't skip ahead:**
   1. Main compilation
   2. Test compilation
   3. Test execution
   The third step is the one R-8 exists for: a build that compiles tests has said nothing about
   whether they ran, so "test compilation" is not evidence and must not be reported as if it were.
4. **When a test breaks because of the reengineering, restore its essence** under the new
   shape — same behavior verified, adapted to the new API/types — rather than deleting it or
   loosening its assertions to force a pass. A deleted test is a check the gate no longer runs
   (R-8); a weakened one is a test that proves less than it claims.
5. **Definition of Done** = REENGINEERING_MODULE compiles, its tests run (if it has any), the gate's
   own output is quoted (R-8), AND the user has explicitly agreed the module is done. A green build
   alone is not DoD.

## Red flags — stop and ask

- About to edit anything under FIXED_MODULES → stop, explain, ask.
- "While I'm here, let me also fix this DEPENDENT_MODULE" → out of scope, leave it excluded; a
  reshape that grew by what the diff touched is exactly what R-13 forbids.
- About to delete or weaken a failing test instead of adapting it to the new design.
- About to report "done" without having asked the user to confirm.
- About to describe the work by the modules it happened to touch rather than by the target list.

## Rationalization table

| Excuse | Reality |
|---|---|
| "It's a tiny fix in a fixed module, not worth asking" | Fixed means source of truth regardless of size. Explain and ask first, every time. |
| "This dependent module still compiles, no harm leaving it in the build" | It will be reshaped later anyway; keeping it wired in couples this reengineering to code that's about to change again, and it widens the pass past its declared list (R-13). |
| "This test checks the old design, I'll just delete it" | Restore what it verifies under the new shape instead — deletion silently drops coverage, and the gate now runs one fewer check (R-8). |
| "Tests compile, so the compile step is behind me" | Compiling tests is step 2; R-8's receipt needs them run, and a gate that only compiles has said nothing about them. |
| "Compiles and tests pass, so it's done" | DoD requires the user's explicit sign-off too, not just a green build. |
| "Tests aren't present, so I can skip that step" | Then step 3 (test execution) is vacuously satisfied — don't invent tests, but don't claim you ran them either. |
