# Stainless feasibility — measured record (2026-09-27)

How the Mill recipe's §8 (`StainlessModule`, `scripts/stainless-verify.sh`) was checked against the real tool, and what
Stainless did with the pilot contracts K1–K3 (spec 2026-09-27 §2). The raw captures kept as parser fixtures are in
`kit/harness/tests/fixtures/stainless/` (`valid.txt`, `invalid.txt`, `unknown.txt`).

## Setup

| | |
|---|---|
| Tool | Stainless **0.9.9.3**, `stainless-dotty-standalone-0.9.9.3-mac-arm64.zip` (its own front end: "Compiling with standard Scala 3.7.2 compiler front end") |
| Platform | macOS arm64 (Darwin 25.6.0), OpenJDK 26.0.2; the native Z3 interface is absent, so every VC ran on the bundled `smt-z3` ("The Z3 native interface is not available. Falling back onto smt-z3.") |
| Build | Mill 1.1.8 (skreeep2's `./mill` wrapper), `--no-server --ticker false`; module `object core extends ScalaModule with StainlessModule { def scalaVersion = "3.8.4" }` |
| Assembly | a scratch project under `mktemp -d`: this recipe's §1 head fragment (extracted from `mill.md`) + §3's `ScalafixExtra.mill` + `buildKit/{package,ArchitectureShapeModule,Stainless}.mill` + `scripts/stainless-verify.sh` + `core/lib/stainless-library.jar` (ScalaSemanticMCP's, sha256 `e1d309c7087bd8b4ba48e4d40fd007212340c61db2d09058fccb5bed8380e2c5`, byte-identical to the distribution's `lib/stainless-library.jar`) |
| Timeout | the script's default, 10 s/VC, unless a row says otherwise |

`Stainless.mill` compiled as written: `override def unmanagedClasspath = Task { super.unmanagedClasspath() ++ Seq(stainlessJar()) }`
and `os.Inherit` both work on Mill 1.1.8 (`show core.unmanagedClasspath` → the one `core/lib/stainless-library.jar`
ref). `core.compile` with the jar on the classpath compiles `Valid.scala` and `Invalid.scala` (exit 0).

## Per-file results

Command: `./mill --no-server --ticker false core.stainlessVerify --targets <file>`.

| Target | Script exit | `./mill` exit | Summary line (ANSI stripped) |
|---|---|---|---|
| `core/src/Valid.scala` | 0 | 0 | `total: 1    valid: 1    (0 from cache, 0 trivial) invalid: 0    unknown: 0    time:    0.09` |
| `core/src/Invalid.scala` | 1 | 1 | `total: 1    valid: 0    (0 from cache, 0 trivial) invalid: 1    unknown: 0    time:    0.08` — counterexample `x: BigInt -> BigInt("0")` |
| `core/src/Pilot.scala` (K1–K3 verbatim) | 2 | 1 | none — the tool stopped at type checking (below) |
| `core/src/Hole.scala` (`{ require(x >= 0); ??? } ensuring (…)`) | 2 | 1 | none — the tool stopped at type checking (below) |
| `core/src/Valid.scala,core/src/Invalid.scala` (two targets) | 1 | 1 | `total: 2    valid: 1    (1 from cache, 0 trivial) invalid: 1    unknown: 0    time:    0.12` |
| `core/src/Nope.scala` (missing file) | 2 | 1 | none — `stainless-verify: SETUP — no such target file: core/src/Nope.scala` |
| `--targets ' , '` | not run | 1 | none — `stainlessVerify: --targets names no file` (the Mill task's own error) |
| no arguments, script direct | 2 | — | `usage: stainless-verify.sh <file.scala> [<file.scala> ...]` |
| `STAINLESS_VERSION=0.0.0`, empty cache, script direct | 2 | — | `curl: (56) The requested URL returned error: 404` then `stainless-verify: SETUP — download failed: https://github.com/epfl-lara/stainless/releases/download/v0.0.0/stainless-dotty-standalone-0.0.0-mac-arm64.zip` |
| `prePush` = `Task.Command { core.stainlessVerify("core/src/Valid.scala")(); () }` (the recipe's step 5 form) | 0 | 0 | `total: 1    valid: 1    (1 from cache, 0 trivial) invalid: 0    unknown: 0    time:    0.01` |
| empty cache, real version, script direct | 0 | — | downloaded and unpacked the release, then verified `Valid.scala` (`stainless-verify: installing Stainless 0.9.9.3 (mac-arm64) -> …`) |

## How `./mill …stainlessVerify` surfaces the script's exit

`./mill` exits **1 for both** script exit 1 and script exit 2 — Mill turns any failed task into its own exit 1. The two
are distinguished by the lines printed, not by Mill's exit:

| Script exit | Script's marker (stderr) | Mill's lines after it |
|---|---|---|
| 1 | `stainless-verify: FAILED — <n> invalid verification condition(s)` | `[error] core.stainlessVerify` / `java.lang.RuntimeException: stainlessVerify failed (exit 1)` + a Mill stack trace |
| 2 | `stainless-verify: SETUP — <reason>` (a missing-arguments run prints `usage: …` instead) | `[error] core.stainlessVerify` / `java.lang.RuntimeException: stainlessVerify failed (exit 2)` + a Mill stack trace |
| 0 | `stainless-verify: OK — no invalid verification conditions (unknown/timeout VCs tolerated)` (stdout) | none; Mill exits 0 |

A run with a summary always also prints `stainless-verify: summary -> <the summary line, ANSI stripped>` on stdout.

## K1–K3 verdicts

**None of K1–K3 is `valid` as the spec states it.** Nothing was reformulated; the human decides (spec §2).

### As written — K1 and K2 do not type-check

The spec's `a ==> r == 32767` parses as `(a ==> r) == 32767`: `==>` begins with `=`, so it has the same precedence as
`==` and associates left. Scala 3.8.4 (`./mill core.compile`) rejects the same two lines. The tool's output on
`Pilot.scala` (ANSI stripped):

```
[  Info  ] Compiling with standard Scala 3.7.2 compiler front end...
[ Error  ] core/src/Pilot.scala:11:24: Found:    (r : Short)
[ Error  ] Required: Boolean
               (v >= 32767.0  ==> r == 32767) &&
                                  ^
[ Error  ] core/src/Pilot.scala:19:46: Found:    (r : Long)
[ Error  ] Required: Boolean
             } ensuring(r => r >= 0 && (frames == 0 ==> r == 0))
                                                        ^
[Warning ] 2 errors found
[  Info  ] Finished compiling
[ Error  ] Stainless terminated with an error.
stainless-verify: SETUP — no Stainless summary in the output (tool or compile error above)
```

(Line 12, K1's `v <= -32768.0 ==> r == -32768`, has the same defect; the compiler reported the first error of the
expression only.)

### Diagnostic probe — the same contracts with the consequent parenthesised

To give the human something to decide on, the three contracts were also run with only `==> r == c` rewritten to
`==> (r == c)` (K1's two saturation clauses, K2's `frames == 0` clause; K3 unchanged; bodies unchanged). This is a
measurement, **not** a reformulation: `Pilot.scala`'s text is as the spec states it, and the probe is not committed as
a kernel. Summary: `total: 36   valid: 31   (0 from cache, 2 trivial) invalid: 3    unknown: 2    time:   21.81`,
script exit 1.

| Contract | Postcondition VC | Other VCs | Verdict |
|---|---|---|---|
| K1 `toPcm16` | valid (all four branch postconditions) | **invalid ×3**, counterexample `v: Double -> NaN` each: `body assertion: Comparison with NaN` at `if v >= 32767.0` (7:8) and at `else if v <= -32768.0` (8:13); `body assertion: Safe floating-point to integer cast non-NaN check` at `v.toShort` (9:10). The cast's lower/upper-bound VCs are valid. | **invalid** — the NaN comparisons and the NaN cast in today's body |
| K2 `framesToNanos` | valid | `body assertion: Multiplication overflow` at `frames.toLong * 1000000000L` → **timeout** (also at `STAINLESS_TIMEOUT=60`); division overflow and division by zero valid | **unknown** (as written: does not type-check) |
| K3 `samplesToNanos` | valid | `body assertion: Multiplication overflow` at `samples * 1_000_000_000L` → **timeout** (also at `STAINLESS_TIMEOUT=60`); division overflow, division by zero valid | **unknown** |

K3 alone (`probe/Unknown.scala`, K3 verbatim in its own object) exits **0**: `total: 6    valid: 5    (3 from cache, 2
trivial) invalid: 0    unknown: 1    time:   10.14` — that capture is `unknown.txt`.

K1's invalid VCs as printed (ANSI stripped):

```
[Warning ]  - Result for 'body assertion: Comparison with NaN' VC for toPcm16 @7:8:
[Warning ] !v.isNaN && !32767.0.isNaN
[Warning ] probe/PilotParen.scala:7:8:  => INVALID
               if v >= 32767.0 then 32767: Short
                  ^^^^^^^^^^^^
[Warning ] Found counter-example:
[Warning ]   v: Double -> NaN
```

(and the same shape for 8:13 and for `'body assertion: Safe floating-point to integer cast non-NaN check' VC for toPcm16 @9:10`).

K2/K3's timeouts as printed:

```
[Warning ]  - Result for 'body assertion: Multiplication overflow' VC for framesToNanos @18:6:
[Warning ] frames < 0 || sampleRate <= 0 || {
[Warning ]   val lhs: Long = frames.toLong
[Warning ]   lhs == 0 || 1000000000 == (lhs * 1000000000) / lhs
[Warning ] }
[Warning ] probe/PilotParen.scala:18:6:  => TIMEOUT
               (frames.toLong * 1000000000L) / sampleRate
                ^^^^^^^^^^^^^^^^^^^^^^^^^^^
```

```
[Warning ]  - Result for 'body assertion: Multiplication overflow' VC for samplesToNanos @24:5:
[Warning ] samples < 0.toLong || sampleRate <= 0 || samples > 9223372036854775807 / 1000000000 || samples == 0 || 1000000000 == (samples * 1000000000) / samples
[Warning ] probe/PilotParen.scala:24:5:  => TIMEOUT
               samples * 1_000_000_000L / sampleRate
               ^^^^^^^^^^^^^^^^^^^^^^^^
```

The spec anticipated `unknown` for "division by a variable"; measured, the divisions are discharged and the
**multiplication-overflow** check is what times out (the overflow check is `x * c / x == c`, itself a nonlinear
division by a variable).

## What `???` produces

- **As the brief shapes it** — `{ require(x >= 0); ??? } ensuring (r => …)` — it does not type-check: the block's type is
  `Nothing`, and the `ensuring` conversion is not tried for it. Tool output:
  ```
  [ Error  ] core/src/Hole.scala:3:45: Found:    (??? : => Nothing)
  [ Error  ] Required: ?{ ensuring: ? }
  [ Error  ] Note that implicit conversions were not tried because the result of an implicit conversion
  [ Error  ] must be more specific than ?{ ensuring: [applied to (r => r >= 0 && r <= x) returning BigInt] }
  ...
  [ Error  ] core/src/Hole.scala:3:45: method ??? in object Predef does not take parameters
  [ Error  ] Stainless terminated with an error.
  stainless-verify: SETUP — no Stainless summary in the output (tool or compile error above)
  ```
  Script exit 2. `./mill core.compile` rejects it too.
- **Typed hole** (probe) — `{ require(x >= 0); (??? : BigInt) } ensuring (r => r >= 0 && r <= x)` — type-checks, and
  Stainless reports the postcondition **valid**: `total: 1    valid: 1    (0 from cache, 0 trivial) invalid: 0    unknown: 0`,
  script exit **0**. Stainless treats `???` as a missing implementation (an unconstrained `choose` satisfying the
  postcondition), which its pipeline line names:
  ```
  [  Info  ] Verification pipeline summary:
  [  Info  ]   missing implementations, cache, choose injection,
  [  Info  ]   nativez3, non-batched
  ```
  **A typed `???` passes this script.** A gate that means "the body is filled" must look for the
  `missing implementations` pipeline marker (or for `???` in the kernel) itself.

## Line patterns (for the engine's parser, Task 3)

Matched on output with ANSI colour stripped (`sed "s/$(printf '\033')\[[0-9;]*m//g"`) and carriage returns turned into
newlines — the tool redraws progress lines with `\r`, so several `[  Info  ]` records can share one physical line.

(In the table, `\|` is a regex alternation `|`, escaped for the Markdown table.)

| What | Pattern (ERE) | Example |
|---|---|---|
| Summary line | `total:[[:space:]]+[0-9]+[[:space:]]+valid:[[:space:]]+[0-9]+.*invalid:[[:space:]]+[0-9]+[[:space:]]+unknown:[[:space:]]+[0-9]+` | `[  Info  ] ║ total: 1    valid: 0    (0 from cache, 0 trivial) invalid: 1    unknown: 0    time:    0.08           ║` |
| Invalid VC (detail) | `^\[Warning \] (.+):([0-9]+):([0-9]+):  => INVALID$` | `[Warning ] core/src/Invalid.scala:3:22:  => INVALID` |
| Its heading (line(s) above it) | `^\[Warning \]  - Result for '([^']+)' VC for ([^ ]+) @([0-9]+):([0-9]+):$` | `[Warning ]  - Result for 'postcondition' VC for inc @3:22:` |
| Counterexample start | `^\[Warning \] Found counter-example:$` | |
| Counterexample binding | `^\[Warning \]   ([^:]+): (.+) -> (.+)$` (one per variable, directly after the start line) | `[Warning ]   x: BigInt -> BigInt("0")` |
| Unknown VC (detail) | `^\[Warning \] (.+):([0-9]+):([0-9]+):  => (TIMEOUT\|UNKNOWN)$` — only `TIMEOUT` was observed | `[Warning ] probe/Unknown.scala:6:5:  => TIMEOUT` |
| Summary-table row | `^\[  Info  \] ║ (.+):([0-9]+):([0-9]+):[[:space:]]+([^ ]+)[[:space:]]+(.+[^ ])[[:space:]]{2,}(valid from cache\|valid\|trivial\|invalid\|timeout\|unknown)[[:space:]]` | `[  Info  ] ║ core/src/Invalid.scala:3:22:  inc    postcondition    invalid     U:smt-z3     0.1  ║` |
| Missing implementation (`???`) | `missing implementations` on a line after `Verification pipeline summary:` | `[  Info  ]   missing implementations, cache, choose injection,` |
| Compile error (no summary) | `^\[ Error  \] (.+):([0-9]+):([0-9]+): (.+)$`, then `^\[ Error  \] Stainless terminated with an error\.$` | `[ Error  ] core/src/Pilot.scala:11:24: Found:    (r : Short)` |
| Script: exit 1 | `^stainless-verify: FAILED — [0-9]+ invalid verification condition\(s\)$` | |
| Script: exit 2 | `^stainless-verify: SETUP — (.+)$`, or `^usage: stainless-verify\.sh` | `stainless-verify: SETUP — no Stainless summary in the output (tool or compile error above)` |
| Script: exit 0 | `^stainless-verify: OK — ` | |
| Mill: script's exit | `stainlessVerify failed \(exit ([0-9]+)\)` | `java.lang.RuntimeException: stainlessVerify failed (exit 2)` |

The summary pattern matches twice per run: the tool's own `[  Info  ] ║ total: …` line and the script's
`stainless-verify: summary -> …` echo of it. Each pattern above was checked with `grep -E` against the three fixtures
and the K1–K3 captures.

Summary-table status words seen: `valid`, `valid from cache`, `trivial`, `invalid`, `timeout`; the summary counts
`timeout` rows under `unknown:`. The path is the target as passed (root-relative), and a VC's detail line and its
summary row carry the same `line:col` (`Invalid.scala:3:22`, `PilotParen.scala:18:6`); several VCs can share one
position (the postcondition and the overflow checks at `18:5`).

## Side effects worth knowing

- Stainless writes a VC cache, **`.stainless-cache/`, in the working directory** (the repo root, since the task runs
  there); later runs report `valid from cache`. A project should git-ignore it.
- The JVM prints four `WARNING: … sun.misc.Unsafe …` lines to stderr on JDK 26 before the tool starts; they carry no
  verdict.
- Stainless type-checks the target with its own Scala 3.7.2 front end, not the module's `scalaVersion`, and does not
  use the module's classpath: a kernel may import only `stainless.*` and what the tool itself models.
