#!/bin/sh
# The single entry point for every harness gate.
#
# Registered in .dsh/hooks.json under DSH's lowercase tool names and in
# .claude/settings.json under Claude Code's names, so one implementation serves both.
# Reads the hook payload from stdin, exits 0 to allow and 2 to block.
#
# The hook is executed by the interpreter in `GATE_SH`, defaulting to `sh` — the value production
# uses, since both wiring files invoke `sh .dsh/gate.sh <sub>`. It is a test seam exactly like
# `GATE_ROOT` (lib.sh): `.dsh/tests/run.sh` passes the interpreter it is itself running under, so
# `dash .dsh/tests/run.sh` exercises gate.sh, every hook and lib.sh under dash instead of only
# proving them `dash -n`-clean. A hook is never the place for a hardcoded interpreter: this one
# line is what makes a POSIX-portability claim measurable rather than aspirational.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"
hook_sh=${GATE_SH:-sh}
GATE_PAYLOAD=$(cat)
export GATE_PAYLOAD

# The subcommand is resolved before the payload is judged, so an unknown one still fails
# loudly even when the payload is unusable.
case "${1:-}" in
  semantic-guard) target="$here/hooks/semantic-guard.sh" ;;
  post-edit)      target="$here/hooks/post-edit.sh" ;;
  turn-end)       target="$here/hooks/turn-end.sh" ;;
  tool-policy)    target="$here/hooks/tool-policy.sh" ;;
  health)         target="$here/hooks/health.sh" ;;
  # The session baseline (F61) is a subcommand of its own because it is a hook of its own: Task 10
  # wires it to SessionStart alongside `health`. It never blocks (see its header).
  baseline)       target="$here/hooks/baseline.sh" ;;
  *) printf 'gate.sh: unknown subcommand %s\n' "${1:-}" >&2; exit 1 ;;
esac

# Fail open, but never in silence: with no JSON reader or an unparseable payload the whole
# gate stands down with a reason instead of letting every hook quietly allow everything.
if ! reason=$(gate_payload_verdict); then
  printf 'DSH harness: gate stands down — %s\n' "$reason" >&2
  exit 0
fi

exec "$hook_sh" "$target"
