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

# --- the contract snapshot (spec 2026-09-27 §3) -------------------------------------------------
# Taken here, BEFORE every early exit below: a session whose file baseline is already recorded, or that
# has no hasher or no git, still needs its kernels' contracts recorded, because the turn-end contract
# guard compares against exactly this. Every registered kernel file that exists is snapshotted, dirty or
# not: the contracts at session start are the human's, whatever state the tree is in. A second
# SessionStart for the same session keeps the first record (the same reason the file baseline does:
# a later snapshot would adopt this session's own contract edits as the human's), and so does a later
# SessionStart that finds the record DELETED (the turn-end guard blocks on that). Never blocks: a
# failure writes an `incomplete: <reason>` header with no `# file` line (the guard then says it cannot
# compare, rather than reading an empty record as "every contract is new") and a one-line note rides
# on this hook's final message. A file the tool answered with an error is left out of the record's
# `# file` lines, and the note names it. The record lives under .dsh/.state/contracts/, which the
# seed's frozen-paths freezes: no agent tool may write it; this hook writes it directly.
snap_note=''
contracts=$(dsh_contract_file "$sid")
snap_has_kernels=0
[ -n "$(dsh_kernels_rows "$root")" ] && snap_has_kernels=1
if [ -f "$contracts" ]; then
  [ "$snap_has_kernels" = 1 ] && snap_note="DSH baseline: session $sid already has a contract snapshot at $contracts — kept, not rewritten."
elif dsh_baseline_readable "$baseline"; then
  # This session already started (its file baseline exists, and the snapshot is always written before
  # it), yet the snapshot is gone: it was deleted. A SessionStart for the same session (resume,
  # compact) must not retake it — that would adopt this session's own contract edits as the human's.
  # The turn-end guard blocks on the missing record instead (fix round 1).
  snap_note="DSH baseline: the contract snapshot for session $sid ($contracts) is gone although this session already started (its file baseline $baseline exists) — it was deleted, and it is not retaken (a new snapshot would adopt this session's own contract edits as the human's). The turn-end contract guard blocks on it; a new session takes a fresh snapshot."
else
  # The record is ALWAYS written on a session's first SessionStart — header-only when no kernel is
  # registered, `incomplete: <reason>` in the header (and no `# file` line) when it could not be taken —
  # so "absent" at turn-end can only mean "deleted" once the session's file baseline exists.
  snap_reason=''
  snap_head="# DSH contract snapshot $sid $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  # One `# escapes <uri> <n>` line per registered kernel file that exists (final review F3): its count of
  # assume(/@extern/@ignore lines. It needs no launcher, so the incomplete record carries it too.
  snap_esc=$(dsh_kernels_rows "$root" | cut -f1 | awk '!seen[$0]++' | while IFS= read -r kf; do
    [ -f "$root/$kf" ] && printf '# escapes %s %s\n' "$kf" "$(dsh_escape_count "$root/$kf")"
  done)
  mkdir -p "$(dirname -- "$contracts")" 2>/dev/null
  snapd=$(mktemp -d 2>/dev/null) || snapd=''
  if [ -z "$snapd" ]; then
    snap_reason='no temporary directory could be made'
  elif [ "$snap_has_kernels" = 0 ]; then
    printf '%s\n' "$snap_head" > "$snapd/new"
    mv -f "$snapd/new" "$contracts" 2>/dev/null
  else
    dsh_kernels_rows "$root" | cut -f1 | awk '!seen[$0]++' | while IFS= read -r kf; do
      [ -f "$root/$kf" ] && printf '%s\n' "$kf"
    done > "$snapd/uris"
    if [ ! -s "$snapd/uris" ]; then
      snap_reason='none of the files in .dsh/policy/kernels.tsv exists'
    elif ! dsh_contract_call "$root" "$snapd/uris" "$snapd/answer.json"; then
      snap_reason=$dsh_contract_reason
    else
      dsh_contracts_unread "$snapd/answer.json" "$snapd/uris" > "$snapd/unread"
      snap_rc=$?
      [ "$snap_rc" = 0 ] && { dsh_contracts_tsv "$snapd/answer.json" > "$snapd/rows"; snap_rc=$?; }
      case "$snap_rc" in
        0) ;;
        2) snap_reason='no jq and no python3 to read the contract_clauses answer' ;;
        *) snap_reason='the contract_clauses answer is not JSON' ;;
      esac
      if [ -z "$snap_reason" ]; then
        cut -f1 "$snapd/unread" > "$snapd/unread.uris"
        awk -v uf="$snapd/unread.uris" 'FILENAME == uf { bad[$0] = 1; next } !($0 in bad)' \
          "$snapd/unread.uris" "$snapd/uris" > "$snapd/covered"
        if [ ! -s "$snapd/covered" ]; then
          snap_reason="the tool answered no kernel file without an error: $(bound_lines "$(cat "$snapd/unread")" 3 | tr '\n' ' ')"
        else
          {
            printf '%s\n' "$snap_head"
            sed 's/^/# file /' "$snapd/covered"
            [ -n "$snap_esc" ] && printf '%s\n' "$snap_esc"
            awk -F'\t' -v cf="$snapd/covered" 'FILENAME == cf { ok[$0] = 1; next } ($1 in ok)' "$snapd/covered" "$snapd/rows"
          } > "$snapd/new"
          snap_rows=$(grep -vc '^#' "$snapd/new")
          if mv -f "$snapd/new" "$contracts" 2>/dev/null; then
            snap_note="DSH baseline: contract snapshot recorded — $snap_rows clause(s) in $(wc -l < "$snapd/covered" | tr -d ' ') kernel file(s) at $contracts; the turn-end contract guard compares against it."
            if [ -s "$snapd/unread" ]; then
              snap_note="$snap_note
DSH baseline: no contract snapshot for $(cut -f1 "$snapd/unread" | tr '\n' ' ')— $(cut -f2 "$snapd/unread" | head -n 1); the contract guard will report that it cannot compare for those file(s)."
            fi
          else
            snap_reason="$contracts could not be written"
          fi
        fi
      fi
    fi
  fi
  if [ -n "$snap_reason" ]; then
    snap_note="DSH baseline: no contract snapshot — $snap_reason; the contract guard will report that it cannot compare"
    # The incomplete record: a header and the escape counts, no `# file` line, so the guard reads every
    # kernel as uncovered ("cannot compare"), never as "no contracts".
    { printf '%s incomplete: %s\n' "$snap_head" "$(printf '%s' "$snap_reason" | tr '\n' ' ')"
      if [ -n "$snap_esc" ]; then printf '%s\n' "$snap_esc"; fi; } > "$contracts.tmp.$$" 2>/dev/null \
      && mv -f "$contracts.tmp.$$" "$contracts" 2>/dev/null
  fi
  [ -n "$snapd" ] && rm -rf "$snapd" 2>/dev/null
fi
# Every exit of this hook carries the snapshot's note, whichever early exit the file baseline takes.
ballow() {
  if [ -n "$snap_note" ]; then
    allow "$1
$snap_note"
  fi
  allow "$1"
}

if dsh_baseline_readable "$baseline"; then
  ballow "DSH baseline: session $sid already has a baseline at $baseline with $(dsh_baseline_rows "$baseline") path(s) — kept, not rewritten (a baseline is the state at session start; rewriting it would adopt this session's own edits as pre-existing)."
fi

# Without a sha256 tool the record could not be compared at turn-end (`dsh_file_hash` answers `-` for
# every path, and `-` = `-` reads as "unchanged"), so writing one would only invite the gate to skip
# paths it cannot check. Nothing is recorded, and the turn-end gate falls back to the tree rule and
# says so — the same behaviour it has when there is no baseline at all.
if ! dsh_has_hasher; then
  ballow "DSH baseline: nothing was recorded — no sha256 tool (shasum or sha256sum) is on PATH, so a record could not be compared at turn-end. The gate will fall back to the tree-based rule and say so."
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
  ballow "DSH baseline: nothing was recorded — $root is not a git work tree, so there is no working tree to snapshot. The turn-end gate will fall back to the tree-based rule and say so."
fi
if [ "$touched_code" != 0 ]; then
  ballow "DSH baseline: nothing was recorded — the working tree could not be read ($dsh_touched_reason). The turn-end gate will fall back to the tree-based rule and say so; it fails closed on that read itself."
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
  ballow "DSH baseline: recorded $rows pre-existing dirty path(s) for session $sid at $baseline. The turn-end gate will check a path that was already dirty only when its content changes from here, and any path that becomes dirty from a clean start."
fi

ballow "DSH baseline: nothing was recorded — $baseline could not be written. The turn-end gate will fall back to the tree-based rule and say so."
