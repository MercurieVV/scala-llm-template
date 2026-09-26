#!/bin/sh
# Session baseline (the SessionStart hook): record which files were already dirty when this session
# started, and the content hash of each, so the turn-end gate can answer for what THIS SESSION
# changed instead of for the whole working tree (F61).
#
# Why this exists: a checkout can carry in-flight work that predates the session — this repository's
# own did, 14 modified Scala files and a module that does not compile. Without a baseline the
# turn-end gate reads all of it as the turn's work, checks those modules on every turn, blocks twice
# on a failure the agent did not cause and then releases with an unverified notice. That is three
# times the cost, permanent noise, and the surest way to teach a user to route around the harness.
# With a baseline, a path already dirty at SessionStart is checked only if its content changes from
# here, a path that was clean then (absent from the record) is checked as soon as it is dirty, and
# the common turn costs a handful of checks instead of the whole dirty tree.
#
# Task 10 wires this to `SessionStart` alongside `health`; until it is wired (or for a session that
# predates it) there is no baseline and the turn-end gate falls back to the tree-based rule and says
# so in its own message.
#
# Never blocks a session start: every failure path here exits 0 with a note. A baseline is a scoping
# hint, not a gate, and a session that cannot start because a snapshot failed would be a worse bug
# than a broader check. The record is `.dsh/.state/baseline-<key>.tsv`, written beside itself and
# renamed into place so no reader ever sees half a baseline; the format and both readers live in the
# F61 section of lib.sh.
#
# A second SessionStart for the same session keeps the first record. The baseline is the state at the
# session's START: rewriting it later would adopt this session's own edits as "pre-existing", which is
# exactly the error this hook exists to prevent.
#
# POSIX sh only: no arrays, no `local`, no `set -e`. `sh -n` and `dash -n` are both clean.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/lib.sh"

root=$(gate_root)
st=$(state_dir)
mkdir -p "$st" 2>/dev/null

sid=$(payload_get session_id)
[ -n "$sid" ] || sid=unknown
baseline=$(dsh_baseline_file "$sid")

if dsh_baseline_readable "$baseline"; then
  allow "DSH baseline: session $sid already has a baseline at $baseline with $(dsh_baseline_rows "$baseline") path(s) — kept, not rewritten (a baseline is the state at session start; rewriting it would adopt this session's own edits as pre-existing)."
fi

# Without a sha256 tool the record could not be compared at turn-end (`dsh_file_hash` answers `-` for
# every path, and `-` = `-` reads as "unchanged"), so writing one would only invite the gate to skip
# paths it cannot check. Nothing is recorded, and the turn-end gate falls back to the tree rule and
# says so — the same behaviour it has when there is no baseline at all.
if ! dsh_has_hasher; then
  allow "DSH baseline: nothing was recorded — no sha256 tool (shasum or sha256sum) is on PATH, so a record could not be compared at turn-end. The gate will fall back to the tree-based rule and say so."
fi

tmpd=$(mktemp -d 2>/dev/null) || tmpd=""
if [ -z "$tmpd" ]; then
  tmpd=${TMPDIR:-/tmp}/dsh-baseline.$$
  mkdir -p "$tmpd" 2>/dev/null
fi
cleanup() {
  _rc=$?
  if [ -n "$tmpd" ]; then rm -rf "$tmpd" 2>/dev/null; fi
  exit "$_rc"
}
trap cleanup 0

dsh_touched_files "$root" "$tmpd/touched"
touched_code=$?
if [ "$touched_code" = 1 ]; then
  allow "DSH baseline: nothing was recorded — $root is not a git work tree, so there is no working tree to snapshot. The turn-end gate will fall back to the tree-based rule and say so."
fi
if [ "$touched_code" != 0 ]; then
  allow "DSH baseline: nothing was recorded — the working tree could not be read ($dsh_touched_reason). The turn-end gate will fall back to the tree-based rule and say so; it fails closed on that read itself."
fi

rows=0
: > "$tmpd/new"
printf '# DSH session baseline %s %s\n' "$sid" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$tmpd/new"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  printf '%s\t%s\n' "$(dsh_file_hash "$root/$path")" "$path" >> "$tmpd/new"
  rows=$((rows + 1))
done < "$tmpd/touched"

if mv -f "$tmpd/new" "$baseline" 2>/dev/null; then
  allow "DSH baseline: recorded $rows pre-existing dirty path(s) for session $sid at $baseline. The turn-end gate will check a path that was already dirty only when its content changes from here, and any path that becomes dirty from a clean start."
fi

allow "DSH baseline: nothing was recorded — $baseline could not be written. The turn-end gate will fall back to the tree-based rule and say so."
