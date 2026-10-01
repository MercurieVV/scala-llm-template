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

# Every scratch directory this hook makes is removed on every exit — including a kill by the hook's own
# timeout mid-hash (fix round 1, M1): a signal exits through the EXIT trap, which a bare kill skips.
tmpd=''
fzd=''
snapd=''
cleanup() {
  _rc=$?
  for _cd in "$tmpd" "$fzd" "$snapd"; do
    if [ -n "$_cd" ]; then rm -rf "$_cd" 2>/dev/null; fi
  done
  exit "$_rc"
}
trap cleanup 0
trap 'exit 143' HUP INT TERM

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

# --- the git-ignored frozen-file record (spec 2026-09-28 §1 item 2) -------------------------------
# git cannot see a git-ignored file, so turn-end's post-hoc check (which reads git) never lists one.
# This records the sha256 of every existing git-ignored file a frozen row answers for
# (`dsh_frozen_ignored_files`, minus the gate's own writes), and turn-end re-hashes each. Written right
# after the contract snapshot — so this session's own snapshot is a legitimate row (written before,
# never rewritten) — and BEFORE every early exit below, like the snapshot. ALWAYS written on a session's
# first SessionStart: header-only when nothing is frozen or ignored, `incomplete: <reason>` in the header
# when something could not be hashed (the rows that could are kept), so "absent" at turn-end means
# "deleted". A second SessionStart keeps the first record, and one that finds it DELETED after the
# session's file baseline exists does not retake it (it would adopt this session's own writes as the
# human's; turn-end blocks instead) — the contract snapshot's rule. Never blocks a session start.
fz_note=''
fz_rec=$(dsh_frozen_record_file "$sid")
fz_rec_rel=.dsh/.state/frozen/$(dsh_state_key "$sid").tsv
if [ -f "$fz_rec" ]; then
  :
elif [ -f "$baseline" ]; then
  case "$(head -n 1 "$baseline" 2>/dev/null)" in
    *' frozen-record')
      fz_note="DSH baseline: the frozen-file record for session $sid ($fz_rec) is gone although this session already wrote one (its file baseline $baseline says so) — it was deleted, and it is not retaken (a new record would adopt this session's own writes to git-ignored frozen files as the human's). The turn-end gate blocks on it; a new session records afresh." ;;
    *)
      fz_note="DSH baseline: session $sid started under an engine that did not record the git-ignored frozen files (its file baseline $baseline predates the record); none is taken mid-session, so they are not compared this session — the turn-end gate notes it. A new session records them." ;;
  esac
else
  fz_head="# DSH frozen-ignored $sid $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fz_reason=''
  fz_n=0
  fz_bad=''
  mkdir -p "$(dirname -- "$fz_rec")" 2>/dev/null
  # A named template, so the directory lands in $TMPDIR (and a test can see it is gone).
  fzd=$(mktemp -d "${TMPDIR:-/tmp}/dsh-frozen.XXXXXX" 2>/dev/null) || fzd=''
  if [ -z "$fzd" ]; then
    fz_reason='no temporary directory could be made'
  elif [ -n "$(dsh_frozen_paths "$root" 2>/dev/null)" ]; then
    : > "$fzd/rows"
    if ! dsh_has_hasher; then
      fz_reason='no sha256 tool (shasum or sha256sum) is on PATH'
    else
      dsh_frozen_ignored_files "$root" "$sid" > "$fzd/list.all" || fz_reason=$dsh_frozen_ignored_reason
      # Never the record inside itself (it is written after this list, and must not describe itself).
      awk -v me="$fz_rec_rel" 'NF && $0 != me' "$fzd/list.all" > "$fzd/list"
      # One hasher run for the whole list (fix round 1, I1): a fork per file cost 33 s for 3000 files.
      dsh_hash_files "$root" "$fzd/list" "$fzd/rows"
      fz_n=$(awk 'END { print NR }' "$fzd/rows")
      awk -F'\t' -v d="$fzd/rows" 'FILENAME == d { ok[$2] = 1; next } !($0 in ok)' "$fzd/rows" "$fzd/list" > "$fzd/bad"
      if [ -s "$fzd/bad" ]; then
        fz_bad="$(head -n 5 "$fzd/bad" | tr '\n' ' ')"
        fz_nbad=$(awk 'END { print NR }' "$fzd/bad")
        [ "$fz_nbad" -gt 5 ] && fz_bad="$fz_bad(and $((fz_nbad - 5)) more)"
        fz_reason="${fz_reason:+$fz_reason; }could not be hashed: ${fz_bad% }"
      fi
    fi
  fi
  if [ -n "$fz_reason" ]; then
    fz_head="$fz_head incomplete: $(printf '%s' "$fz_reason" | tr '\n' ' ')"
    fz_note="DSH baseline: the frozen-file record ($fz_rec) is incomplete — $fz_reason; turn-end compares the $fz_n file(s) it did record and notes the rest as not compared."
  elif [ "$fz_n" -gt 0 ]; then
    fz_note="DSH baseline: recorded $fz_n git-ignored frozen file(s) at $fz_rec; the turn-end gate blocks when one of them changes."
  fi
  if { printf '%s\n' "$fz_head"; if [ -n "$fzd" ] && [ -f "$fzd/rows" ]; then cat "$fzd/rows"; fi; } > "$fz_rec.tmp.$$" 2>/dev/null \
     && mv -f "$fz_rec.tmp.$$" "$fz_rec" 2>/dev/null; then
    :
  else
    rm -f "$fz_rec.tmp.$$" 2>/dev/null
    fz_note="DSH baseline: the frozen-file record $fz_rec could not be written, so the git-ignored frozen files cannot be compared this session; the turn-end gate notes it on every turn."
  fi
  [ -n "$fzd" ] && rm -rf "$fzd" 2>/dev/null
fi
if [ -n "$fz_note" ]; then
  snap_note="${snap_note:+$snap_note
}$fz_note"
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
# ` frozen-record` closes the header when this session's git-ignored frozen-file record exists as the
# baseline is taken (written above, or kept): it is how turn-end tells "the record was deleted" (block)
# from "this session started under an engine that never wrote one" (a note — a re-vendor mid-session
# must not block every later turn of every live session). `dsh_baseline_readable` reads only the
# header's first 23 bytes, so an older reader is unaffected.
fz_mark=''
[ -f "$fz_rec" ] && fz_mark=' frozen-record'
printf '# DSH session baseline %s %s%s\n' "$sid" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$fz_mark" > "$tmpd/new"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  printf '%s\t%s\n' "$(dsh_file_hash "$root/$path")" "$path" >> "$tmpd/new"
  rows=$((rows + 1))
done < "$tmpd/touched"

# Two more kinds of row come from the unfiltered changed-path read (`dsh_changed_paths`):
#
# * Dirty FROZEN paths of every other extension (spec 2026-09-28 §1): turn-end's post-hoc check
#   blocks on any frozen path this session changed, and "already dirty at SessionStart, unchanged
#   since" can only be told apart from "changed this session" by a row here. The touched set is
#   `.scala`/`.sc`/`.mill` only, so without these rows the human's dirty `README.md` under a freeze
#   would block every turn.
# * DELETED `.scala`/`.sc` paths, hash `-`: turn-end checks the module that owns a source file this
#   session deleted, and a file the human had already deleted before the session must not count as
#   this session's deletion. The touched set keeps only files that exist, so it has no row for them.
#
# A read that fails here records nothing at all (the same verdict as a failed first read): a baseline
# missing these rows would make turn-end block the human's own pre-existing work, which is a wrong
# statement about the session.
fz_rows=$(dsh_frozen_paths "$root" 2>/dev/null) || :
dsh_changed_paths "$root" "$tmpd/changed"
changed_code=$?
if [ "$changed_code" != 0 ]; then
  ballow "DSH baseline: nothing was recorded — the working tree could not be read for the deleted and frozen paths ($dsh_touched_reason). The turn-end gate will fall back to the tree-based rule and say so; it fails closed on that read itself."
fi
while IFS= read -r path; do
  [ -n "$path" ] || continue
  grep -qxF -- "$path" "$tmpd/touched" 2>/dev/null && continue
  dsh_gate_written "$path" "$sid" && continue
  bl_keep=0
  case "$path" in
    *.scala|*.sc) if [ ! -e "$root/$path" ] && [ ! -L "$root/$path" ]; then bl_keep=1; fi ;;
  esac
  if [ "$bl_keep" = 0 ] && [ -n "$fz_rows" ] && dsh_frozen_match any "$path" "$fz_rows"; then bl_keep=1; fi
  [ "$bl_keep" = 1 ] || continue
  printf '%s\t%s\n' "$(dsh_file_hash "$root/$path")" "$path" >> "$tmpd/new"
  rows=$((rows + 1))
done < "$tmpd/changed"

if mv -f "$tmpd/new" "$baseline" 2>/dev/null; then
  ballow "DSH baseline: recorded $rows pre-existing dirty path(s) for session $sid at $baseline. The turn-end gate will check a path that was already dirty only when its content changes from here, and any path that becomes dirty from a clean start."
fi

ballow "DSH baseline: nothing was recorded — $baseline could not be written. The turn-end gate will fall back to the tree-based rule and say so."
