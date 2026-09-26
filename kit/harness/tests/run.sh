#!/bin/sh
# Fixture runner: each case directory holds payload.json, expect.code, optionally expect.grep (one
# needle per line, each of which must appear), optionally env (KEY=VALUE lines) and optionally root/
# (a subtree copied into the scratch root). Stubs in .dsh/tests/bin go first on PATH, so no case ever
# runs real Mill.
#
# The gate is run with the interpreter that is running this file, so `sh .dsh/tests/run.sh` and
# `dash .dsh/tests/run.sh` are two different runs of run.sh, gate.sh, every hook and lib.sh, and the
# banner below names which one this is. That is what the GATE_SH seam buys (F58): gate.sh execs the
# hook through `GATE_SH`, default `sh` — the value production uses, since .dsh/hooks.json and
# .claude/settings.json both invoke `sh .dsh/gate.sh <sub>` — and this runner passes, and exports,
# the interpreter it resolved below, so a dash run genuinely EXECUTES every hook under dash
# (measured with hooks that record their own interpreter: 124 of 124 invocations under dash, where a
# fixture's own gate call used to stay under `sh`). Before that seam gate.sh ended in
# `exec sh "$target"`, and this note had to say the opposite: every "verified under dash" claim in
# this branch was `dash -n` plus direct probes, and a copy whose hooks recorded their own interpreter
# showed every invocation under `sh` in a dash run of this file.
#
# Optional extras, all additive to the two files above:
#   run_twice          invoke the gate a second time with the same payload and environment, require
#                      the same exit code, and fold the second run's output into the greps below.
#   mutate_between     a script run (with $SCRATCH_ROOT exported, cwd the scratch root) after the
#                      first invocation and before the second: how a case changes the edited file's
#                      bytes, or a map row's capabilities, and proves the second run re-checks.
#   pre_gate           a script run (cwd the scratch root, $SCRATCH_ROOT exported) BEFORE the gate is
#                      invoked: how a case builds a state the gate has to notice -- a cache it must
#                      reject, an index file older than the cache. Same output and exit contract as
#                      post_gate below; a non-zero exit fails the case, because a gate tested against
#                      a world the case failed to build proves nothing.
#   post_gate          a script run (cwd the scratch root, $SCRATCH_ROOT exported) after EVERY
#                      invocation above: how a case asserts on the FILES the hook wrote rather than
#                      on the hook's output. Its stdout joins the case output, so an expect.grep can
#                      read what it printed; a non-zero exit fails the case, because a post-check
#                      that could not run must never read as "the file was as expected". It also
#                      receives GATE_OUT_FILE, the gate's combined output so far, which is how a case
#                      asserts the ABSENCE of a text (expect.grep can only require presence).
#   expect.millcalls N the mill stub must have been called exactly N times, read as the number of
#                      lines in $scratch/mill.log — which must exist, so a fixture that cannot see
#                      Mill at all fails instead of reading "no log" as "no calls".
#   expect.loggrep     one fixed string per line, each of which must appear in $scratch/mill.log —
#                      this is how a case asserts the command lines the hook issued.
#   git_init           make a real git repository in the scratch root and commit everything the case
#                      shipped, so the Stop gate (which reads the working tree, not the payload) has
#                      a base to compare against.
#   post_git           a script run after that commit, with cwd the scratch root: how a case then
#                      modifies, adds or deletes a file, which is what "this turn touched" means.
# SCRATCH_ROOT, GATE_ROOT, GATE_SH, PATH and MILL_STUB_LOG are the runner's own seams: a case's env
# comes first and these are applied after it, so no fixture can point the gate at another root, run
# the hooks under another interpreter, put another mill first, or hide Mill's invocations from the
# assertions. SCRATCH_ROOT is also substituted into an env value literally (one parameter expansion,
# never an eval), so a fixture can name the scratch root without knowing it; an env value must not
# contain spaces, since lines are word-split. The same token in payload.json is substituted the same
# way — a payload names an ABSOLUTE path in production, so that is the only way a fixture can assert
# on a file under its own root — and a payload the token does not appear in is passed through
# untouched (the substitution runs only when the token is there).
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cases_dir="$repo/.dsh/tests/cases"
passed=0
failed=0
cases=0

# The interpreter running this file is the one that must run the gate: `ps` names it (a bare name on
# macOS, a path on Linux, nothing at all in some containers), so a path is reduced to its basename and
# `sh` is the fallback — comparing a `ps` path against a `command -v` path is what makes this
# assertion flaky, and that is what the basename normalisation avoids. The assertion is what makes
# `dash .dsh/tests/run.sh` mean what it says.
runner=$(ps -p $$ -o comm= 2>/dev/null | tr -d ' ')
case "$runner" in
  */*) runner=$(basename -- "$runner") ;;
esac
[ -n "$runner" ] || runner=sh
shell_bin=$(command -v "$runner" 2>/dev/null) || shell_bin=""
[ -n "$shell_bin" ] || shell_bin=$runner
printf '# gate interpreter: %s (this run is under %s)\n' "$shell_bin" "$runner"
if [ "$(basename -- "$shell_bin")" != "$runner" ]; then
  printf 'FAIL the gate interpreter resolved to %s while this file runs under %s\n' "$shell_bin" "$runner"
  failed=$((failed + 1))
fi
# Exported as well as passed per invocation: a fixture's own post_git may run the gate itself (the
# turn-end baseline cases record a SessionStart baseline that way), and those scripts invoke it as
# `"${GATE_SH:-sh}" …` — production's value by default, this run's interpreter when the runner set
# one. Without the export, six of the 124 hook invocations of a dash run would quietly stay under
# `sh` (measured: exactly that, before these two lines existed), and the banner's claim would be
# true of the runner and not of everything it claims to exercise.
export GATE_SH="$shell_bin"

for case_dir in "$cases_dir"/*/; do
  [ -d "$case_dir" ] || continue
  cases=$((cases + 1))
  name=$(basename "$case_dir")
  scratch=$(mktemp -d)
  export SCRATCH_ROOT="$scratch"
  mkdir -p "$scratch/.dsh/.state"
  if [ -d "$case_dir/root" ]; then cp -R "$case_dir/root/." "$scratch/"; fi

  # A real git repository inside the scratch root, for the Stop gate, which reads the turn's touched
  # files from `git status`/`git diff` rather than from the hook payload. `git_init` makes the repo
  # and commits everything the case shipped, so that repository is the base the case turns dirty;
  # `post_git` (a script, run only once that commit exists) is how a case then modifies, adds or
  # deletes a file — the state a Stop gate has to read. Both flags are absent from every other case,
  # which is also how `turn-end-no-git-notes` gets a scratch root with no repository at all.
  #
  # Either step failing fails the case here and now: a gate that reads git is only as meaningful as
  # the repository the case built for it, and "the setup did not happen" must never be read as "the
  # hook allowed it".
  if [ -f "$case_dir/git_init" ]; then
    if ! ( cd "$scratch" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ); then
      printf 'FAIL %s: git_init could not build the base repository\n' "$name"
      failed=$((failed + 1)); rm -rf "$scratch"; continue
    fi
  fi
  if [ -f "$case_dir/post_git" ]; then
    if ! ( cd "$scratch" && "$shell_bin" "$case_dir/post_git" ); then
      printf 'FAIL %s: post_git could not turn the base repository dirty\n' "$name"
      failed=$((failed + 1)); rm -rf "$scratch"; continue
    fi
  fi

  sub=$(cat "$case_dir/subcommand" 2>/dev/null || echo "")
  if [ -z "$sub" ]; then
    printf 'FAIL %s: missing subcommand file\n' "$name"
    failed=$((failed + 1)); rm -rf "$scratch"; continue
  fi
  # The expected exit code is read before the gate runs rather than after, so a case missing it fails
  # as a broken fixture instead of as "the gate exited 0 and I wanted nothing" (M8). A present but
  # empty file is the same defect: no exit code can equal the empty string.
  if [ ! -s "$case_dir/expect.code" ]; then
    printf 'FAIL %s: missing or empty expect.code (the case cannot say what it expects)\n' "$name"
    failed=$((failed + 1)); rm -rf "$scratch"; continue
  fi
  if [ ! -f "$case_dir/payload.json" ]; then
    printf 'FAIL %s: missing payload.json (the gate would be handed an empty payload)\n' "$name"
    failed=$((failed + 1)); rm -rf "$scratch"; continue
  fi

  env_args=""
  if [ -f "$case_dir/env" ]; then
    # `|| [ -n "$line" ]`: `read` fails at EOF, but a file whose last line has no trailing newline
    # still has content in `$line` when it does — without the guard, `while read` drops that last
    # line silently instead of erroring, which is exactly how four fixtures' env vars went missing
    # unnoticed. The other two read loops below (`expect.grep`, `expect.loggrep`) already carry it;
    # this is the one that didn't.
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      # A fixture names paths under the scratch root as $SCRATCH_ROOT, which only this loop can
      # resolve: env(1) takes the values verbatim, so the shell would hand it the literal text. The
      # substitution is one parameter expansion, so a value is never evaluated as shell code (and a
      # value may not contain spaces, since the arguments below are word-split).
      case "$line" in
        *'$SCRATCH_ROOT'*)
          line="${line%%\$SCRATCH_ROOT*}$scratch${line#*\$SCRATCH_ROOT}" ;;
      esac
      env_args="$env_args $line"
    done < "$case_dir/env"
  fi

  # shellcheck disable=SC2086
  # The case's own env comes first: the runner's seams (GATE_ROOT, GATE_SH, PATH, MILL_STUB_LOG) are
  # applied after it and therefore win, so no fixture can point the gate at a root of its own
  # choosing, run the hooks under another interpreter, put another mill first, or log Mill's
  # invocations somewhere the assertions cannot see. GATE_SH is what gate.sh execs the hook with, so
  # this is the line that makes a dash run of this file a dash run of every hook.
  #
  # The payload may spell a path under the scratch root as `$SCRATCH_ROOT`: a tool payload carries an
  # ABSOLUTE path in production, so a case that asserts on a file under its own root has no other way
  # to name one. Substituting it is a sed over the file's TEXT (never an eval), and only when the
  # token is actually there; `&` and `\` in the scratch path would need escaping and mktemp makes
  # neither, which is the same assumption the env seam above already makes about spaces.
  payload_file="$case_dir/payload.json"
  if grep -qF -- '$SCRATCH_ROOT' "$payload_file" 2>/dev/null; then
    payload_file="$scratch/payload.json"
    sed "s|\$SCRATCH_ROOT|$scratch|g" "$case_dir/payload.json" > "$payload_file"
  fi
  mill_log="$scratch/mill.log"
  : > "$mill_log"
  # The case's own pre-check, before the gate is invoked: how a case builds a state the gate has to
  # NOTICE -- a cache it must reject, an index file whose mtime is older than the cache. cwd is the
  # scratch root and $SCRATCH_ROOT is exported; a non-zero exit fails the case, because a gate
  # tested against a world the case failed to build proves nothing. Its stdout joins the case output
  # below, so an expect.grep can read what it reported.
  pre_out=''
  if [ -f "$case_dir/pre_gate" ]; then
    pre_out=$(cd "$scratch" && "$shell_bin" "$case_dir/pre_gate" 2>&1)
    pre_code=$?
    pre_out="
--- pre_gate (exit $pre_code) ---
$pre_out"
    [ "$pre_code" = 0 ] || fail_case_pending=1
  fi
  out=$(env $env_args GATE_ROOT="$scratch" GATE_SH="$shell_bin" PATH="$repo/.dsh/tests/bin:$PATH" MILL_STUB_LOG="$mill_log" \
        "$shell_bin" "$repo/.dsh/gate.sh" "$sub" < "$payload_file" 2>&1)
  code=$?
  if [ -n "$pre_out" ]; then out="$pre_out$out"; fi

  want_code=$(cat "$case_dir/expect.code")
  ok=1
  # What actually failed, one line per failed assertion (M8): the old message said
  # `exit 0 (wanted 0)` for a case whose exit code was right and whose grep was wrong, which sends
  # the reader after a defect that is not there. `problems` starts empty and every failing check
  # appends its own line, so the FAIL below reports exactly the checks that failed.
  problems=''
  fail_case() { # fail_case <one-line reason>
    ok=0
    problems="$problems
     $1"
  }
  # A pre_gate that could not run is reported here, once fail_case exists: the invocation above has
  # already happened, and a failing setup must not read as a passing assertion.
  [ "${fail_case_pending:-0}" = 1 ] && fail_case "the case's own pre_gate script failed"
  fail_case_pending=0
  # A second invocation: a hook that caches a verdict must answer the same way and must not run Mill
  # again (which expect.millcalls then proves). mutate_between may change the world in between — the
  # edited file's bytes, a map row's capabilities — which is the other half of the cache contract.
  # Its output joins the first run's, so every grep below has to hold for both.
  if [ -f "$case_dir/run_twice" ]; then
    if [ -f "$case_dir/mutate_between" ]; then
      if ! ( cd "$scratch" && "$shell_bin" "$case_dir/mutate_between" ) >/dev/null 2>&1; then
        fail_case "the case's own mutate_between script failed (it could not change the world between the two runs)"
        out="$out
mutate_between failed"
      fi
    fi
    # shellcheck disable=SC2086
    out2=$(env $env_args GATE_ROOT="$scratch" GATE_SH="$shell_bin" PATH="$repo/.dsh/tests/bin:$PATH" MILL_STUB_LOG="$mill_log" \
           "$shell_bin" "$repo/.dsh/gate.sh" "$sub" < "$payload_file" 2>&1)
    code2=$?
    [ "$code2" = "$want_code" ] || fail_case "the second run exited $code2 (wanted $want_code)"
    out="$out
--- second run (exit $code2) ---
$out2"
  fi
  # The case's own post-check, before any assertion reads `out`: it runs after every invocation, so
  # it sees the state the gate left, and its stdout joins `out`, which is how a case asserts on a
  # file the hook wrote (the fallback log, a cache) with the same expect.grep every other assertion
  # uses. A non-zero exit is a case failure, never a silent skip: a post-check that could not run
  # says nothing about the file.
  # The gate's captured output so far (every invocation, combined stdout+stderr) is handed to the
  # post-check as a file, GATE_OUT_FILE: expect.grep can only require a needle to be PRESENT, and a
  # case whose claim is an absence -- the holdout's raw assertion text must never reach the agent --
  # asserts it in post_gate against this file.
  if [ -f "$case_dir/post_gate" ]; then
    printf '%s\n' "$out" > "$scratch/gate.out"
    pg_out=$(cd "$scratch" && GATE_OUT_FILE="$scratch/gate.out" "$shell_bin" "$case_dir/post_gate" 2>&1)
    pg_code=$?
    out="$out
--- post_gate (exit $pg_code) ---
$pg_out"
    [ "$pg_code" = 0 ] || fail_case "the case's own post_gate script failed (exit $pg_code)"
  fi
  [ "$code" = "$want_code" ] || fail_case "the gate exited $code (wanted $want_code)"
  # One fixed string per line, each of which must appear in the output (the same shape
  # expect.loggrep has, and a single-line file behaves exactly as it always did): a case whose
  # evidence is two separate facts -- a verdict and what a post_gate found -- needs two needles,
  # and `grep -qF` on the whole file as one string would silently require them to be adjacent.
  if [ -f "$case_dir/expect.grep" ]; then
    while IFS= read -r want_grep || [ -n "$want_grep" ]; do
      [ -n "$want_grep" ] || continue
      printf '%s' "$out" | grep -qF -- "$want_grep" \
        || fail_case "the output does not contain the expected text: $want_grep"
    done < "$case_dir/expect.grep"
  fi
  # What Mill was actually asked to do: the stub appends one line per invocation to MILL_STUB_LOG.
  # The log is created empty above and every stub writes to this exact path, so its absence is a
  # harness failure, never an implicit "Mill was never called".
  if [ -f "$case_dir/expect.millcalls" ]; then
    want_calls=$(cat "$case_dir/expect.millcalls")
    if [ ! -f "$mill_log" ]; then
      fail_case "the mill log $mill_log is missing: no stub could record its invocations"
      out="$out
the mill log $mill_log is missing: no stub could record its invocations"
    else
      calls=$(wc -l < "$mill_log" | tr -d ' ')
      if [ "$calls" != "$want_calls" ]; then
        fail_case "Mill was called $calls time(s) (wanted $want_calls)"
      fi
    fi
  fi
  if [ -f "$case_dir/expect.loggrep" ]; then
    while IFS= read -r want_line || [ -n "$want_line" ]; do
      [ -n "$want_line" ] || continue
      grep -qF -- "$want_line" "$mill_log" 2>/dev/null \
        || fail_case "the mill log lacks the expected line: $want_line"
    done < "$case_dir/expect.loggrep"
  fi

  if [ "$ok" = 1 ]; then
    printf 'ok   %s\n' "$name"; passed=$((passed + 1))
  else
    printf 'FAIL %s:%s\n--- output ---\n%s\n' "$name" "$problems" "$out"
    failed=$((failed + 1))
  fi
  rm -rf "$scratch"
done

if [ "$cases" = 0 ]; then
  printf 'FAIL no cases found in %s\n' "$cases_dir"
  exit 1
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
