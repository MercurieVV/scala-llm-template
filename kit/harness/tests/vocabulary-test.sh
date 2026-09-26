#!/bin/sh
# Direct tests for tool-name vocabulary parity: the same call, sent with the DSH tool name and with
# the Claude Code one, must reach the same verdict.
#
# Why this file exists (F65): the registration checks in tests/wiring-test.sh can see which matcher
# sends which tool to which hook, but they cannot see what the hook does with the payload it is handed.
# The two dialects differ ONLY in the tool-name spelling -- `read` vs `Read`, `bash` vs `Bash` -- and a
# hook that compares the name as a literal silently allows every call from the other dialect. That is
# F64: `tool-policy.sh` matched `bash` exactly, so a Claude Code session's `Bash` payload exited 0 and
# `sbt` was never denied there, while every registration check passed.
#
# `semantic-guard.sh` is vocabulary-tolerant on purpose ("a family, never a spelling") and
# `post-edit.sh` accepts the capitalized write names; the audit behind F64 is a table in
# .superpowers/sdd/2026-09-16-dsh-harness/task-10-report.md.
#
# The fixture is hermetic: the gate runs against a scratch root with a healthy verdict, one
# `src/A.scala`, and NO module map and NO `./mill` wrapper, so `post-edit` cannot decide and denies
# without any Mill ever running; the mill stub from tests/bin goes first on PATH as in tests/run.sh.
# The root also ships an INDEX covering `src/A.scala` (F72): the semantic-guard rows assert that both
# vocabularies reach the same DENY, and a file the index does not cover stands down instead -- which
# would make every read row pass while proving nothing about the deny it is there to compare.
# Nothing here touches the repository's own tree or its `.dsh/.state`.
#
# A row asserts the expected verdict FIRST (exit code plus the first line of the message) and only then
# that the two spellings agree. Without that order, two spellings that both fell through to "allow"
# would agree perfectly and prove nothing -- exactly the shape of the bug this file exists for.
#
# Like tests/lib-test.sh, tests/health-test.sh and tests/wiring-test.sh, this file is deliberately NOT
# wired into tests/run.sh: it is a direct test, not a fixture case.
#
# Run: .dsh/tests/vocabulary-test.sh
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo" || exit 1
passed=0
failed=0

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
is() { # is <name> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$2], got [$3]"; fi
}
has() { # has <name> <needle> <haystack>
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1: [$2] not found in [$3]" ;;
  esac
}
lacks() { # lacks <name> <needle> <haystack>
  case "$3" in
    *"$2"*) bad "$1: [$2] unexpectedly found in [$3]" ;;
    *) ok "$1" ;;
  esac
}

# --- the fixture root, and a copy of the running harness ----------------------------------------

scratch=$(mktemp -d)
root="$scratch/root"     # the gate root every hook resolves its state and paths against
copy="$scratch/copy"     # a byte-for-byte copy of gate.sh, lib.sh and hooks/, for the RED at the end

mkdir -p "$root/.dsh/.state" "$root/src"
printf 'healthy=1\n' > "$root/.dsh/.state/health"
: > "$root/src/A.scala"
# The index that covers it, in the layout Mill writes: `*/META-INF/semanticdb/<source path>.semanticdb`.
mkdir -p "$root/out/src/semanticDbData.dest/classes/META-INF/semanticdb/src"
: > "$root/out/src/semanticDbData.dest/classes/META-INF/semanticdb/src/A.scala.semanticdb"
[ -f "$root/src/A.scala" ] || bad "the fixture root could not be built under $scratch"
[ -f "$root/out/src/semanticDbData.dest/classes/META-INF/semanticdb/src/A.scala.semanticdb" ] \
  || bad "the fixture root's index could not be built under $scratch"

mkdir -p "$copy/.dsh"
cp .dsh/gate.sh .dsh/lib.sh "$copy/.dsh/" 2>/dev/null
cp -R .dsh/hooks "$copy/.dsh/hooks" 2>/dev/null
[ -f "$copy/.dsh/gate.sh" ] && [ -f "$copy/.dsh/hooks/tool-policy.sh" ] \
  || bad "the harness copy could not be built under $copy"

# --- running one hook ------------------------------------------------------------------------

# run_hook <harness dir> <subcommand> <payload>: leaves the merged output in hook_out and the exit
# code in hook_rc. The harness dir is the repository (the shipped hooks) or the copy (the revert).
run_hook() {
  hook_out=$(printf '%s' "$3" | CLAUDE_PROJECT_DIR="$root" PATH="$repo/.dsh/tests/bin:$PATH" \
             sh "$1/.dsh/gate.sh" "$2" 2>&1)
  hook_rc=$?
}

# The key line of a verdict: what the bridge's summary shows the model first, and what a reader of a
# deny actually reads. Everything the gate says beyond it is detail for the same decision.
key_line() { printf '%s\n' "$1" | sed -n '1p'; }

# {"tool_name":"<tool>",<tail>} -- one payload, two spellings of the same call.
payload_for() { printf '{"tool_name":"%s",%s}' "$1" "$2"; }

# --- the parity runner ------------------------------------------------------------------------

# vfail is the runner's own verdict, as in tests/wiring-test.sh: vbad feeds it and the real counters
# both, so a run in `$( )` (the reverted copy) reports only through its exit status and its output.
vfail=0
vok() { ok "$1"; }
vbad() { vfail=1; bad "$1"; }
vis() { # vis <name> <want> <got>
  if [ "$2" = "$3" ]; then vok "$1"; else vbad "$1: wanted [$2], got [$3]"; fi
}
vhas() { # vhas <name> <needle> <haystack>
  case "$3" in
    *"$2"*) vok "$1" ;;
    *) vbad "$1: [$2] not found in [$3]" ;;
  esac
}

parity() { # parity <label> <harness> <sub> <dsh tool> <cc tool> <payload tail> <want rc> [needle]
  p_label=$1; p_harness=$2; p_sub=$3; p_dsh=$4; p_cc=$5; p_tail=$6; p_want=$7; p_needle=${8:-}
  run_hook "$p_harness" "$p_sub" "$(payload_for "$p_dsh" "$p_tail")"
  p_a_rc=$hook_rc; p_a_line=$(key_line "$hook_out")
  run_hook "$p_harness" "$p_sub" "$(payload_for "$p_cc" "$p_tail")"
  p_b_rc=$hook_rc; p_b_line=$(key_line "$hook_out")
  vis "$p_label: $p_dsh is decided (rc $p_want)" "$p_want" "$p_a_rc"
  if [ -n "$p_needle" ]; then vhas "$p_label: $p_dsh says why" "$p_needle" "$p_a_line"; fi
  vis "$p_label: $p_cc reaches the same verdict" "$p_a_rc" "$p_b_rc"
  vis "$p_label: $p_cc says the same thing" "$p_a_line" "$p_b_line"
}

run_parity() { # run_parity <harness dir>
  vfail=0
  p_h=$1
  # tool-policy: the tool family is the whole gate for this hook, so Bash/bash parity is the F64 fix.
  parity "tool-policy: sbt is denied" "$p_h" tool-policy bash Bash \
         '"tool_input":{"command":"sbt compile"}' 2 'BLOCKED by tool-policy'
  # An allow row, so a hook that denied everything could not pass this file.
  parity "tool-policy: mill is allowed" "$p_h" tool-policy bash Bash \
         '"tool_input":{"command":"./mill -j 1 preCommit"}' 0
  # semantic-guard: the read half, the write half, and the bash family, each with a healthy verdict
  # in the fixture root so the fallback denies instead of standing down.
  parity "semantic-guard: reading a .scala is denied" "$p_h" semantic-guard read Read \
         '"tool_input":{"file_path":"src/A.scala"}' 2 'BLOCKED by semantic-guard'
  parity "semantic-guard: editing a .scala is denied" "$p_h" semantic-guard edit Edit \
         '"tool_input":{"file_path":"src/A.scala"}' 2 'BLOCKED by semantic-guard'
  parity "semantic-guard: a bash read of a .scala is denied" "$p_h" semantic-guard bash Bash \
         '"tool_input":{"command":"cat src/A.scala"}' 2 'BLOCKED by semantic-guard'
  # post-edit: the edit and write spellings, both denied because the fixture root has no module map
  # (fail closed), plus a non-Scala path that must be allowed.
  parity "post-edit: editing a .scala is denied" "$p_h" post-edit edit Edit \
         '"tool_input":{"file_path":"src/A.scala"}' 2 'BLOCKED by the DSH gate'
  parity "post-edit: writing a .scala is denied" "$p_h" post-edit write Write \
         '"tool_input":{"file_path":"src/A.scala"}' 2 'BLOCKED by the DSH gate'
  parity "post-edit: a non-Scala path is allowed" "$p_h" post-edit edit Edit \
         '"tool_input":{"file_path":"src/notes.md"}' 0

  # NotebookEdit has no DSH counterpart to compare against, so the decision recorded in
  # post-edit.sh's header is asserted directly: a notebook payload carries `notebook_path`, never
  # `tool_input.file_path`, so the hook reads an empty path and allows without looking anything up.
  run_hook "$p_h" post-edit "$(payload_for NotebookEdit '"tool_input":{"notebook_path":"src/A.ipynb"}')"
  vis "post-edit: NotebookEdit is the documented no-op" "0" "$hook_rc"
  vis "post-edit: NotebookEdit says nothing" "" "$(key_line "$hook_out")"

  # semantic-guard never classifies NotebookEdit: it is in none of the read/write/bash families, so it
  # takes the `*) exit 0` arm. Also the right verdict -- a notebook is not a Scala source -- and
  # asserted here because the hook's family list is what decides it, not the matcher that sends it.
  run_hook "$p_h" semantic-guard "$(payload_for NotebookEdit '"tool_input":{"notebook_path":"src/A.ipynb"}')"
  vis "semantic-guard: NotebookEdit is allowed (unclassified)" "0" "$hook_rc"
  vis "semantic-guard: NotebookEdit says nothing" "" "$(key_line "$hook_out")"
  return "$vfail"
}

# --- the shipped hooks --------------------------------------------------------------------------

run_parity "$repo"
is "the shipped hooks decide alike in both vocabularies" "0" "$?"

# --- non-vacuity: revert the Bash acceptance in the copy, and the parity rows must fail ----------
# The same runner, against a copy whose tool-policy accepts only the lowercase name: the DSH rows must
# still pass and the CC rows must fail. That is the F64 defect reproduced on demand, and it is what
# makes the parity assertion above worth trusting.

reverted="$copy/.dsh/hooks/tool-policy.sh"
# Structural, not line-shaped: drop the `Bash` alternative wherever it is spelled, and let the guard
# below catch a rewrite that no longer spells it that way (a stale revert must not look like a pass).
sed 's/bash|Bash/bash/' "$repo/.dsh/hooks/tool-policy.sh" > "$reverted.new" 2>/dev/null
if [ -s "$reverted.new" ] && ! cmp -s "$repo/.dsh/hooks/tool-policy.sh" "$reverted.new"; then
  mv "$reverted.new" "$reverted"
  out=$(run_parity "$copy" 2>&1); rc=$?
  is "reverted copy: the parity run fails" "1" "$rc"
  has "reverted copy: the Bash row is what fails" \
      "tool-policy: sbt is denied: Bash reaches the same verdict" "$out"
  lacks "reverted copy: the DSH row still passes" \
      "FAIL tool-policy: sbt is denied: bash is decided" "$out"
  has "reverted copy: the failure carries both verdicts" "wanted [2], got [0]" "$out"
else
  bad "the revert of the Bash acceptance changed nothing — the RED proof would be vacuous"
fi

rm -rf "$scratch"
printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
