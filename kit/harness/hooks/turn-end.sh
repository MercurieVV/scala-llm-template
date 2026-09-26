#!/bin/sh
# Turn-end gate (the Stop hook): the turn may not end while the modules it touched still fail the
# checks the repository's own commit gate runs. Task 8's per-edit gate catches a violation in the
# same breath as the edit; this is the last line of defence behind it, so "done" means something.
#
# What "this turn touched" means: the SESSION's changes, not the agent's account and not the whole
# working tree. `git status --porcelain -uall` (untracked files included, and `-uall` so a file in a
# brand-new directory is named rather than its directory) plus `git diff --name-only HEAD`, filtered
# to `.scala`/`.sc` and `.mill` — the same derivation `dsh_touched_files` hands to
# `.dsh/engine/hooks/baseline.sh`, which snapshots it at SessionStart. A path that was already dirty in that
# snapshot is checked only when its content changed since (hash comparison), a path that is new since
# it is always checked, and a path that was clean then and is dirty now is absent from the record and
# is therefore checked too (F61). Without a baseline for the session — the hook is not wired, or the
# session predates it — the gate falls back to the tree-based rule and says so in every message it
# prints, so the reader knows the gate is then broader than the session.
#
# That scoping is what makes the gate usable in a checkout that carries in-flight work: this
# repository's own had 14 modified Scala files and a module that does not compile, none of them the
# agent's. For attribution it means a diagnostic naming a file that only pre-dates the session is a
# note, never a block — F53's rule below, applied to the paths the gate actually checked. Ignored
# files are never touched files, and a turn with nothing new to check prints nothing at all.
#
# Blocking rule (F53/F57) — only diagnostics naming a file this turn touched:
#
#   * the check names a touched file, by absolute path, by the root-relative spelling zinc prints, or
#     through a symlinked root (`pwd -P` canonicalises; /tmp and /var on macOS are symlinks) -> BLOCK;
#   * the check names no file this gate recognises (.scala/.sc/.java/.mill) -> BLOCK, because nothing
#     in that text can be attributed to another change (a Mill-level failure with no diagnostic
#     behind it);
#   * the check names only files this turn did not touch -> a NOTE, never a block. Six of the
#     repository's twenty-nine modules are scalafmt-dirty today and `checkFormat` lists every
#     misformatted file in a module, so blocking there would punish an agent for drift it did not
#     cause and cannot fix from what it changed — F53's whole point.
#
# `fix --check`, `fixStrict`, `compile` and `test.compile` run through `.dsh/engine/hooks/feedback.sh`
# (spec 2026-09-20 diagnostic→instruction): the agent is shown DIAGNOSTIC/INSTRUCTION lines rendered
# from the run, the raw log is kept under `.dsh/.state/feedback/`, and the rule above reads that RAW
# log, never the rendered block — attribution has to see every path Mill printed, and the renderer
# folds them. mill-scalafix's own failure line is generic ("A Scalafix linter error was reported"),
# but the log it sits in names every file a diagnostic is in, so `fix --check` and `fixStrict` are
# attributable per file like `compile` is; this used to be the one hole in the rule.
#
# Attribution is a substring test against the touched paths' spellings, which is Task 8's trade-off
# too: a diagnostic naming a sibling whose name contains a touched path over-attributes and blocks,
# where a stricter test would under-attribute and silently allow. Erring toward the block is the
# deliberate direction.
#
# Build files (`.mill`, F56): a module-map lookup answers `-` for them, so a touched build file is
# checked by the build-validity probe instead — `./mill --ticker false moduleMap` must succeed. It
# catches a `.mill` file that does not parse or type-check, in `build.mill` or any sibling, because
# Mill compiles them together. It does NOT catch a build that compiles with a broken graph (measured:
# a `moduleDeps` on a module that does not exist still answered exit 0 and listed the row), and it is
# a validity probe, not a behaviour probe: such a break surfaces the moment any gate runs a task on
# it, which is loud but is not this probe.
#
# Sequential, never parallel: one module at a time, one Mill invocation per check (Task 8's model).
# scalafix's OrganizeImports was observed flip-flopping between two valid orderings under Mill's
# parallel execution of many modules — `.githooks/pre-commit` records it — so no two scalafix tasks
# ever run concurrently here. Every Mill call passes `--ticker false` (the ticker prefixes every line
# of a task's output with `<n>] `) and `--color false` (FORCE_COLOR is common in agent environments).
#
# Mill is `./mill` from the root when the wrapper is there, falling back to `mill` on PATH — the same
# resolution `.dsh/engine/hooks/post-edit.sh` and `.dsh/engine/module-map.sh` use, and what lets a fixture scratch
# root be checked by a stub.
#
# Never runs tests, and mutates exactly one thing: the purrism rewrite stage (`fixRanges`) applies the
# scalafix patches that lie wholly inside the lines this turn changed, then blocks so the agent reviews
# them — and undoes them when they break the compile. Nothing else writes: `checkFormat`,
# `fix --check`, `fixStrict`, `compile`, `test.compile` and `moduleMap` write nothing, and
# `reformat`/a bare `fix` rewrite the tree (the remedy line asks the agent to run those). The test
# SUITE is `prePush`'s job (F60), so every message this gate prints that reports a verdict says so — a
# green turn-end must never be read as "the tests passed". A turn with nothing to check prints nothing
# at all: it has no verdict to misread.
#
# Fail closed. A non-zero exit from `.dsh/engine/module-map.sh` means the gate cannot name the module that
# owns a touched file, so it blocks with the lookup's own reason rather than reading it as "ungated".
# The same for a map row this gate cannot read, for a root with no Mill to run at all, and for a git
# that is present but whose read of the working tree failed: each of those is "cannot know what to
# check", which is exactly when this gate must not allow. The one thing that is NOT a failure is a
# root that is not a git work tree at all — there the gate allows, loudly, because it never blocks a
# turn whose files it cannot even enumerate.
#
# The retry cap, because an unconditionally blocking Stop hook is worse than a visible failure: the
# bridge always reports `stop_hook_active: false`, so the gate limits itself. `.dsh/.state/
# turn-end-<session>.count` counts the attempts this turn has had blocked; two are allowed, and on the
# third failing attempt the turn is released with a loud notice and a timestamped line in
# `.dsh/.state/unverified.log`. The cap is per TURN, not per session: any turn this gate allows
# resets the counter to 0, and so does a release, so a single broken module can never silence the
# gate for the rest of the session — it costs two forced continuations each time, and the log records
# every unverified end. If the counter cannot be written the gate cannot stay bounded at all, so it
# releases the turn and says so rather than blocking forever. A block raised before any check ran (a
# broken map, a missing Mill, a failed git read) goes through the same counter, so no single failure
# mode can block a session without end.
#
# Output is bounded twice — per section by `bound_lines`, and as a whole by `bound_bytes` — and both
# of those live in lib.sh (F59/F62: one implementation, shared with post-edit, with the EPIPE
# suppression that keeps shell noise out of the reason an agent reads). Exit codes: 0 allows the turn
# to end, 2 blocks it. Nothing else, ever.
#
# POSIX sh only: no arrays, no `local`, no `set -e`. `sh -n` and `dash -n` are both clean.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/lib.sh"

root=$(gate_root)
st=$(state_dir)
mkdir -p "$st" 2>/dev/null
tab=$(printf '\t')

tmpd=$(mktemp -d 2>/dev/null) || tmpd=""
if [ -z "$tmpd" ]; then
  tmpd=${TMPDIR:-/tmp}/dsh-turn-end.$$
  mkdir -p "$tmpd" 2>/dev/null
fi
# Exit 0 or 2 only, whatever happens in between: any other status is read as "the hook itself
# errored", which is a fail-open verdict nobody sees. An unexpected status is turned into a loud
# stand-down instead — the turn ends unchecked, and it says so.
cleanup() {
  _rc=$?
  if [ -n "$tmpd" ]; then rm -rf "$tmpd" 2>/dev/null; fi
  case "$_rc" in
    0|2) exit "$_rc" ;;
    *) printf 'DSH turn-end: the gate itself failed (exit %s), so this turn ends unchecked — nothing above was verified.\n' "$_rc" >&2
       exit 0 ;;
  esac
}
trap cleanup 0

max_lines=15
max_report_bytes=4000
max_notes_bytes=2000
max_attempts=2

# The shared report plumbing (`section`, in lib.sh) writes into these by name, and diff-scoped
# verification below is the first thing that can call it — before the module map is even read, so
# a prose-only or module-map-broken turn still gets checked. Declared here, once, so nothing later
# resets what diff-scoped verification already filed.
blocked=0
noted=0
nchecks=0
report=''
notes=''
remedies=''
ran=''
blockmods=''
probeline=''
vd_note=''
rw_note=''

# The session's attempt counter, sanitised so a session id can never name a path of its choosing.
# The value is stripped of whitespace before it is trusted, so a counter written by `echo` (or by
# hand) counts as the number it is rather than as junk.
sid=$(payload_get session_id)
[ -n "$sid" ] || sid=unknown
counter="$st/turn-end-$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_').count"
count=$(cat "$counter" 2>/dev/null | tr -d '[:space:]')
case "$count" in ''|*[!0-9]*) count=0 ;; esac
reset_counter() { printf '0' 2>/dev/null > "$counter" || :; }

# --- this session's baseline, and the one line that says which rule is in force (F61) ----------
# Read here, before anything can block: `block` calls `baseline_note`, and a verdict raised before
# this point (an unenterable root) must not run a function that does not exist yet. All three states
# below are decided from the file and the PATH alone — no `cd` is needed for any of them.
baseline=$(dsh_baseline_file "$sid")
baseline_rows=0
skipped=0
seen_base=0
if ! dsh_baseline_readable "$baseline"; then
  # No record at all, or a file at that path that is not one: never read the second as "the tree was
  # clean at SessionStart", which would be a false scope statement about the session.
  if [ -f "$baseline" ]; then baseline_state=unreadable; else baseline_state=tree; fi
elif ! dsh_has_hasher; then
  # A record whose hashes cannot be compared (`dsh_file_hash` answers `-` for everything, and `-` = `-`
  # reads as "unchanged") would skip every pre-existing dirty path. Fail closed: check the tree.
  baseline_state=nohash
else
  baseline_state=session
  baseline_rows=$(dsh_baseline_rows "$baseline")
fi

# The one line that tells a reader which rule produced the verdict in front of them: in scoped mode
# how much of the tree the snapshot took out of scope, in every fallback mode that the gate was
# broader than the session and why. `unknown` (a verdict reached before this file was read) prints
# neither. The counts describe what was considered, not what was in the tree: a path that was dirty
# at SessionStart and is clean again now is not "checked".
baseline_note() {
  case "$baseline_state" in
    session)
      if [ "$baseline_rows" -eq 0 ]; then
        printf "Session baseline: scoped to this session's changes — the tree was clean at SessionStart, so every dirty path is this session's.\n"
      elif [ "$skipped" -gt 0 ]; then
        printf "Session baseline: scoped to this session's changes — %s of the %s path(s) already dirty at SessionStart are still dirty and unchanged since, and were not checked.\n" "$skipped" "$baseline_rows"
      elif [ "$seen_base" -gt 0 ]; then
        printf "Session baseline: scoped to this session's changes — all %s path(s) already dirty at SessionStart that are still dirty changed since and were checked.\n" "$seen_base"
      else
        printf "Session baseline: scoped to this session's changes — none of the %s path(s) already dirty at SessionStart is dirty now.\n" "$baseline_rows"
      fi ;;
    nohash)
      printf 'No sha256 tool (shasum or sha256sum) on PATH, so the SessionStart baseline cannot be compared: the gate read the whole working tree instead of skipping paths it cannot check.\n' ;;
    unreadable)
      printf 'The SessionStart baseline at %s is not a baseline record this gate can read, so it was ignored: the gate read the whole working tree rather than assume the session started clean.\n' "$baseline" ;;
    tree)
      printf 'No SessionStart baseline for this session, so the gate read the whole working tree: files that were already dirty before this session were checked too. Wire .dsh/engine/hooks/baseline.sh (gate.sh baseline) to SessionStart to scope the gate to this session.\n' ;;
  esac
  return 0
}

# A blocking verdict, whatever raised it: the cap first, then the counter, then the denial. Keeping
# this in one place is what makes the cap hold even for a denial raised before any check ran.
block() { # block <the whole message>; its first line is the headline the unverified log records
  _body=$(bound_bytes "$1" "$max_report_bytes")
  # A pending diff-scoped note (`vd_note`) must reach the agent on EVERY exit, not just the allowing
  # ones: `allow` call sites flush it themselves, but every `block` call site — the four fail-closed
  # ones raised before any check ran, and the ones from the compile chain below — do not, so it goes
  # here instead of at each site (the same reason the attempt cap and counter live here: one place is
  # what makes it hold for a call site nobody enumerated).
  if [ -n "$vd_note" ]; then
    _body="$_body

$vd_note"
  fi
  # The rewrite stage's notes (a fixRanges that could not run, a rewrite that was undone) likewise.
  if [ -n "$rw_note" ]; then
    _body="$_body

$rw_note"
  fi
  _head=$(first_line "$1")
  _note=$(baseline_note)
  if [ -n "$_note" ]; then
    _body="$_body

$_note"
  fi
  # F60, guaranteed for every block message — including the four fail-closed ones raised before any
  # check ran, which used to go out without it.
  case "$_body" in
    *'Tests are NOT run by this gate'*) ;;
    *) _body="$_body
Tests are NOT run by this gate — ./mill prePush compiles and runs them." ;;
  esac
  if [ "$count" -ge "$max_attempts" ]; then
    _log="$(date -u '+%Y-%m-%dT%H:%M:%SZ') turn-end: unverified completion — $_head"
    _where="$st/unverified.log could not be written"
    if printf '%s\n' "$_log" 2>/dev/null >> "$st/unverified.log"; then
      _where="logged in $st/unverified.log"
    fi
    reset_counter
    allow "DSH harness: the turn-end gate is still failing after $((count + 1)) attempts and is releasing the turn so it can end. THIS TURN ENDS UNVERIFIED.
$_body

$_log  ($_where)
The counter is reset, so the next turn gets two fresh attempts before this happens again."
  fi
  if printf '%s' "$((count + 1))" 2>/dev/null > "$counter"; then
    deny "BLOCKED by the DSH gate: $_body"
  fi
  # The attempt could not be recorded, so the cap can never be reached: releasing is the only bounded
  # behaviour left. Loud, and logged, but never a silent endless block.
  _log="$(date -u '+%Y-%m-%dT%H:%M:%SZ') turn-end: unverified completion (attempt counter $counter is not writable) — $_head"
  printf '%s\n' "$_log" 2>/dev/null >> "$st/unverified.log"
  allow "DSH harness: the turn-end gate cannot record this attempt in $counter, so it cannot bound itself; it is releasing the turn rather than blocking forever. THIS TURN ENDS UNVERIFIED.
$_body

$_log
Tests are NOT run by this gate — ./mill prePush compiles and runs them."
}

cd "$root" 2>/dev/null || block "the turn-end gate cannot check this turn — the gate root $root cannot be entered, so this turn's touched files cannot be read from git.
Fix the root, then end the turn again; this gate fails closed rather than checking nothing."
# `pwd -P` because `pwd` is logical: a root reached through a symlink would otherwise not match the
# absolute paths Mill prints.
rootp=$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P) || rootp="$root"

# --- what this turn touched, from git, scoped to this session (F61) ---------------------------
# A path that was already dirty when the session started is checked only if its content changed since
# (hash comparison against the SessionStart baseline); a path that is new since the baseline is
# always checked; a path that was clean then and is dirty now is absent from the baseline and is
# therefore checked too. Which rule is in force — and why — is decided above, in `baseline_note`.
dsh_touched_files "$root" "$tmpd/touched"
touched_code=$?
if [ "$touched_code" = 1 ]; then
  reset_counter
  allow "DSH turn-end: nothing was checked — $root is not a git work tree, so the files this turn touched cannot be read from git, and this gate never blocks a turn whose files it cannot read.
Install or repair the repository if that is a mistake; nothing here is a verdict on the turn's Scala, and the tests (./mill prePush) were not run."
fi
if [ "$touched_code" != 0 ]; then
  # git is there but the working tree could not be read: the gate does not know what to check, and an
  # empty set here would read as "nothing changed" — the silent allow this branch exists to prevent.
  block "this turn cannot be checked — the working tree could not be read, so the gate cannot tell what this turn touched.
$dsh_touched_reason
Fix git (or the repository) and end the turn again; this gate fails closed rather than reading a failed read as a clean tree."
fi

: > "$tmpd/scala"
: > "$tmpd/mill"
: > "$tmpd/spell"
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if [ "$baseline_state" = session ]; then
    baseline_hash=$(dsh_baseline_hash "$baseline" "$path")
    if [ -n "$baseline_hash" ]; then
      seen_base=$((seen_base + 1))
      if [ "$baseline_hash" = "$(dsh_file_hash "$path")" ]; then
        skipped=$((skipped + 1))
        continue
      fi
    fi
  fi
  case "$path" in
    *.scala|*.sc) printf '%s\n' "$path" >> "$tmpd/scala" ;;
    *.mill) printf '%s\n' "$path" >> "$tmpd/mill" ;;
  esac
  # Every spelling a check's output could use for this path: root-relative, absolute through the
  # canonical root, and absolute through the root as the caller spelled it. Attribution below is a
  # substring test against these — and only against the paths the gate actually checked, so a
  # diagnostic naming a file that only pre-dates the session is a note, not a block.
  printf '%s\n' "$path" >> "$tmpd/spell"
  printf '%s\n' "$rootp/$path" >> "$tmpd/spell"
  if [ "$rootp" != "$root" ]; then printf '%s\n' "$root/$path" >> "$tmpd/spell"; fi
done < "$tmpd/touched"

# --- diff-scoped verification (spec 2026-09-24 §2) ---------------------------------------------
# Runs BEFORE the module map is even read: it is cheap, it is the only check here scoped to the
# changed LINES rather than to whole files, and a failure blocks with a precise message instead of
# paying for a module-map lookup and a compile that would say the same thing less clearly. It also
# has to run before the "nothing to run" early exit below, because a prose-only turn has no module
# to map at all and diff-scoped verification is the only check that can ever fire for it. This does
# NOT excuse a Scala file the module map cannot place: that stays fail-closed (F56) exactly as
# before, whether the cause is a broken build or no build wrapper at all — `[ -x "$root/mill" ]`
# cannot tell those apart (a wrapper can lose its executable bit in transit — tar, a Docker `COPY` —
# which is the ordinary "build is broken" case F56 exists for), so there is no safe way to relax one
# without the other.
#
# Its findings never go through `classify`: the script reports only on lines this turn changed, so
# there is nothing to attribute to another change and no third verdict to reach. A non-zero exit is
# already this turn's, so it blocks straight away.
#
# A non-blocking note (`vd_note`, printed unconditionally near the end via `add_line`, exactly like
# `probeline` — and flushed by `block()` itself for every path that blocks instead, so no exit ever
# drops it) stays OUT of `noted`/`nchecks`/`section note`: those feed the F53 line ("N of M checks
# failed on files this turn did not touch"), which is a statement about ATTRIBUTION — a diagnostic
# that might belong to a file this turn did not touch. Diff-scoped verification's advisories (no
# `timeout` on PATH, no semantic index yet, a turn with nothing checkable) are not that; folding them
# into F53 would make it claim an attribution question it was never asked, the same reason
# `turnEndTests` keeps its own draft failures in `fb_noted` rather than `noted`. And when it already
# succeeded (exit 0, non-empty stdout), that stdout is already in "--- <title> ---" section format —
# printed by verify-diff.sh's own `section note` — so it is surfaced as-is rather than wrapped twice.
vd_out=$(DSH_VERIFY_BASELINE=HEAD sh "$here/verify-diff.sh" 2>&1)
vd_code=$?
if [ "$vd_code" = 2 ]; then
  # The headline and the remedy name the finding families actually present, read off verify-diff's
  # own blocking section titles: a memorised table is not a name that does not exist, and "fix the
  # names" under it hands the agent the wrong remedy. A block whose titles this list does not know
  # still blocks, under a neutral headline.
  vd_head=''
  vd_fix=''
  case "$vd_out" in
    *"--- names this turn introduced that do not resolve ---"*|*"--- symbols outside the module's allowed prefixes"*|*"--- dependency coordinates that do not resolve ---"*)
      vd_head="this turn introduced something that does not exist"
      vd_fix="Fix the names above (or the coordinate, or the policy row's module)." ;;
  esac
  case "$vd_out" in
    *"--- construct(s) whose literals are largely the tests' own values ---"*)
      vd_head="${vd_head:+$vd_head, and }this turn's changed code lists the visible tests' own values instead of computing them"
      vd_fix="${vd_fix:+$vd_fix
}A construct whose literals are largely the tests' own values clears only when you compute the values instead of listing the tests' own — restructure that construct. A legitimate table is exempted by an allow row in .dsh/policy/memorisation.tsv, which only the human writes: ask for one, do not add it." ;;
  esac
  [ -n "$vd_head" ] || { vd_head="diff-scoped verification blocked the lines this turn changed"; vd_fix="Fix what each section above names."; }
  block "$vd_head.
$vd_out
$vd_fix
Then end the turn again. This check reads only the lines this turn changed, so nothing here is pre-existing breakage."
elif [ "$vd_code" != 0 ]; then
  vd_note="verify-diff.sh exited $vd_code, so the names this turn introduced were NOT checked:
$vd_out"
elif [ -n "$vd_out" ]; then
  vd_note=$vd_out
fi

# --- which modules own them, and what each row grants -----------------------------------------
: > "$tmpd/mods"      # <module> TAB <capabilities>
: > "$tmpd/modfiles"  # <module> TAB <root-relative path>, one line per touched file
seen=''
while IFS= read -r path; do
  [ -n "$path" ] || continue
  lookup=$(sh "$here/module-map.sh" "$rootp/$path" 2>"$tmpd/err")
  lookup_code=$?
  if [ "$lookup_code" != 0 ]; then
    block "this turn cannot be checked — the module map could not decide which module owns $path, so the files this turn touched cannot be mapped to the checks they need.
$(cat "$tmpd/err" 2>/dev/null)
The build or its map is broken, and this gate fails closed rather than letting a Scala change end unexamined: run ./mill --ticker false moduleMap by hand, fix what it reports, then end the turn again."
  fi
  [ "$lookup" = "-" ] && continue
  module=$(printf '%s\n' "$lookup" | cut -f1)
  caps=$(printf '%s\n' "$lookup" | cut -f2)
  if [ -z "$module" ]; then
    block "this turn cannot be checked — the module map answered with something this gate cannot read for $path: [$lookup].
The map at $st/modules.tsv is malformed; run ./mill --ticker false moduleMap by hand and fix what it reports, then end the turn again."
  fi
  case " $seen " in
    *" $module "*) ;;
    *) seen="$seen $module"; printf '%s\t%s\n' "$module" "$caps" >> "$tmpd/mods" ;;
  esac
  printf '%s\t%s\n' "$module" "$path" >> "$tmpd/modfiles"
done < "$tmpd/scala"

# --- nothing to run ---------------------------------------------------------------------------
# Diff-scoped verification can still have something to say even when nothing here reaches the
# compile chain — a prose-only turn has no module to map at all — so its note is flushed through
# `allow` instead of a bare `exit 0`, which would drop it.
if [ ! -s "$tmpd/mods" ] && [ ! -s "$tmpd/mill" ]; then
  reset_counter
  allow "$vd_note"
fi

mill=$(resolve_mill "$root") || mill=""
if [ -z "$mill" ]; then
  block "this turn cannot be checked — there is no Mill to run the checks with, neither $root/mill (the repository's own wrapper) nor a mill on PATH.
Install Mill (or restore the wrapper), then end the turn again; this gate fails closed rather than checking nothing."
fi

# --- run the checks, and decide ----------------------------------------------------------------
# Does a check's output name a file this turn touched, in any of the spellings recorded above?
attributable() {
  while IFS= read -r _spelling; do
    [ -n "$_spelling" ] || continue
    case "$1" in *"$_spelling"*) return 0 ;; esac
  done < "$tmpd/spell"
  return 1
}

# `names_file` (does a check's output name a file at all — the `.mill` in its vocabulary is this
# gate's business), `bound_lines` and `section` all come from lib.sh: F62 moved the first two there
# so this hook and post-edit cannot drift apart, and M3 moved `section` (identical in both files) and
# the Mill resolution with it. The `max_lines` it cuts each section to is set above.

# classify <title> <raw output> <exit code> [<shown text>]: count and file a failed check. Attribution
# (`attributable`, `names_file`) reads the RAW output — F53 needs every path Mill printed — and the
# section shown to the agent is <shown text> when given (the feedback wrapper's rendered block),
# else the raw output itself.
classify() {
  [ "$3" = 0 ] && return 0
  _show=${4:-$2}
  if attributable "$2"; then
    blocked=$((blocked + 1))
    section blocking "$1 (failed; names a file this turn touched)" "$_show"
  elif ! names_file "$2" 'scala|sc|java|mill'; then
    blocked=$((blocked + 1))
    section blocking "$1 (failed; names no source file, so nothing there is attributable to another change)" "$_show"
  else
    noted=$((noted + 1))
    section note "$1 (failed; names only files this turn did not touch — not blocking)" "$_show"
  fi
  return 0
}

check() { # check <label> <mill task...>
  _label=$1
  shift
  nchecks=$((nchecks + 1))
  # `compile`, `fix --check`, `fixStrict` and `test.compile` speak in diagnostics, so they run through
  # the feedback wrapper via lib.sh's `dsh_check_through_wrapper` (spec 2026-09-20 diagnostic→
  # instruction; one implementation, shared with post-edit): the agent reads DIAGNOSTIC/INSTRUCTION
  # lines (DSH_CHECK_SHOWN -- the raw text when the block is UNREADABLE:/INFRA:), the raw log stays
  # under .dsh/.state/feedback/, and `classify` attributes on the RAW text (DSH_CHECK_RAW).
  # checkFormat's output is a file list, not diagnostics, and stays raw.
  case "$_label" in
    *.checkFormat)
      _out=$("$mill" --ticker false --color false "$@" 2>&1)
      _code=$?
      _raw=$_out ;;
    *)
      dsh_check_through_wrapper "$_label" "$mill" "$@"
      _code=$DSH_CHECK_RC
      _raw=$DSH_CHECK_RAW
      _out=$DSH_CHECK_SHOWN ;;
  esac
  ran="$ran$_label, "
  classify "$_label" "$_raw" "$_code" "$_out"
}

# --- purrism rewrites on this turn's changed lines (spec 2026-09-25 §2) ----------------------------
# The gate used to only REPORT a pending rewrite. It now applies the ones inside the lines this turn
# changed, then blocks once so the agent reviews them: a Stop hook that allowed would end the turn with
# nobody looking. Code the agent did not write is never rewritten (fixRanges keeps only the patches
# whose every edit is in range, so a patch reaching outside — an import it needs — is skipped whole,
# and what it leaves may not compile). A rewrite that breaks the compile is undone: every file of that
# module the rewrite changed gets its original back. Not at the commit boundary: rewriting the index
# would change what is being committed.
#
# Every module is attempted before anything blocks — `block` never returns, so blocking inside the
# loop would leave every later module unrewritten. What the stage has to SAY without blocking (a
# fixRanges that could not run, a rewrite that was undone) goes to `rw_note`, flushed like `vd_note`
# by `block()` and by the allow path: it stays out of `noted`/`section note`, whose F53 line claims N
# checks "failed on files this turn did not touch", which none of these is. "Was anything applied" is
# decided by comparing each file with its saved original, never by fixRanges' own count (a count of
# patches, and one that says nothing about bytes).
: > "$tmpd/rw-diffs"
rw_mods=''
rw_sep=''
# When the stage may run at all. Only under the SESSION baseline: in every fallback (no record, an
# unreadable one, no hash tool) the gate cannot tell the agent's edits from a human's in-flight work,
# and a stage that MUTATES files must fail safe there — the checks below fail closed by checking more,
# a rewrite would fail open by rewriting someone else's code. And not at the attempt cap: this turn-end
# would then release the turn, and a rewrite applied on the releasing attempt would end it with nobody
# reviewing. Skipping is said, once, when a touched module grants scalafix (else there was nothing to
# skip); `fix --check` in the chain still gates those modules exactly as before.
rw_skip=''
if [ "$baseline_state" != session ]; then
  rw_skip="the rewrite stage needs the session baseline to know which lines are yours, and this session has none usable (see the baseline line below), so nothing was rewritten."
elif [ "$count" -ge "$max_attempts" ]; then
  rw_skip="this turn-end is at the attempt cap ($count blocked attempts) and would release the turn, so a rewrite now would end it unreviewed; nothing was rewritten."
fi
if [ -n "$rw_skip" ]; then
  : > "$tmpd/rw-mods"
  if awk -F"$tab" '(","$2",") ~ /,scalafix,/ { f = 1 } END { exit !f }' "$tmpd/mods"; then
    rw_note="--- purrism rewrites skipped ---
$rw_skip The fix --check below still gates every module."
    rw_sep='
'
  fi
else
  cp "$tmpd/mods" "$tmpd/rw-mods"
fi
while IFS="$tab" read -r rw_mod rw_caps; do
  [ -n "$rw_mod" ] || continue
  case ",$rw_caps," in *,scalafix,*) ;; *) continue ;; esac
  # The module's touched files that still exist (a deleted file has nothing to rewrite), each with its
  # original saved first: a file whose original cannot be kept is never handed to fixRanges, because a
  # rewrite of it could not be undone.
  : > "$tmpd/rw-files"
  : > "$tmpd/rw-ranges"
  rw_unsaved=''
  rw_predirty=''
  while IFS="$tab" read -r rw_m rw_f; do
    [ "$rw_m" = "$rw_mod" ] || continue
    [ -f "$rw_f" ] || continue
    # A path with a baseline row was already dirty at SessionStart: its diff against HEAD mixes a
    # human's edits with the agent's, and the baseline keeps only a hash, so the agent's own lines
    # cannot be separated out. Such a file is never rewritten (untracked ones included).
    if [ -n "$(dsh_baseline_hash "$baseline" "$rw_f")" ]; then
      rw_predirty="$rw_predirty $rw_f"
      continue
    fi
    if ! { mkdir -p "$tmpd/orig/$(dirname -- "$rw_f")" && cp "$rw_f" "$tmpd/orig/$rw_f"; } 2>/dev/null; then
      rw_unsaved="$rw_unsaved $rw_f"
      continue
    fi
    printf '%s\n' "$rw_f" >> "$tmpd/rw-files"
    if git ls-files --error-unmatch -- "$rw_f" >/dev/null 2>&1; then
      git diff -U0 HEAD -- "$rw_f" > "$tmpd/rw-diff" 2>/dev/null
      dsh_diff_ranges "$tmpd/rw-diff" "$tmpd/rw-one"
      cat "$tmpd/rw-one" >> "$tmpd/rw-ranges"
    else
      # Untracked: every line is this turn's. `awk NR`, not `wc -l`, so a last line with no newline
      # still counts.
      rw_n=$(awk 'END { print NR }' "$rw_f" 2>/dev/null)
      case "$rw_n" in ''|*[!0-9]*) rw_n=0 ;; esac
      [ "$rw_n" -gt 0 ] && printf '%s\t0\t%s\n' "$rw_f" "$rw_n" >> "$tmpd/rw-ranges"
    fi
  done < "$tmpd/modfiles"
  if [ -n "$rw_unsaved" ]; then
    rw_note="$rw_note${rw_sep}--- purrism rewrites (not applied) in $rw_mod ---
the original of$rw_unsaved could not be saved, so it was not rewritten (a rewrite nothing can undo is never made); the fix --check still gates it."
    rw_sep='
'
  fi
  if [ -n "$rw_predirty" ]; then
    rw_note="$rw_note${rw_sep}--- purrism rewrites (not applied) in $rw_mod ---
each of$rw_predirty was already dirty at SessionStart, so its diff mixes your lines with lines that are not yours; it was not rewritten, and the fix --check still gates it."
    rw_sep='
'
  fi
  [ -s "$tmpd/rw-ranges" ] || continue

  # `--rangesFile` is a NAMED argument: Mill rejects a positional one for a Task.Command parameter.
  rw_out=$("$mill" --ticker false --color false "$rw_mod.fixRanges" --rangesFile "$tmpd/rw-ranges" </dev/null 2>&1)
  rw_code=$?
  if [ "$rw_code" != 0 ]; then
    # fixRanges may have written before it failed: nothing it left is kept unreviewed, and a restore
    # that fails is named, never dropped.
    rw_failed=''
    while IFS= read -r rw_f; do
      cmp -s "$tmpd/orig/$rw_f" "$rw_f" && continue
      cp "$tmpd/orig/$rw_f" "$rw_f" 2>/dev/null && cmp -s "$tmpd/orig/$rw_f" "$rw_f" || rw_failed="$rw_failed $rw_f"
    done < "$tmpd/rw-files"
    rw_note="$rw_note${rw_sep}--- purrism rewrites (not applied) in $rw_mod ---
$rw_mod.fixRanges exited $rw_code, so nothing was rewritten; the fix --check still gates this module:
$(bound_lines "$rw_out" 5)"
    if [ -n "$rw_failed" ]; then
      rw_note="$rw_note
COULD NOT RESTORE the original of$rw_failed after the failed fixRanges — restore it by hand."
    fi
    rw_sep='
'
    continue
  fi

  : > "$tmpd/rw-changed"
  while IFS= read -r rw_f; do
    cmp -s "$tmpd/orig/$rw_f" "$rw_f" || printf '%s\n' "$rw_f" >> "$tmpd/rw-changed"
  done < "$tmpd/rw-files"
  [ -s "$tmpd/rw-changed" ] || continue

  rw_cout=$("$mill" --ticker false --color false "$rw_mod.compile" </dev/null 2>&1)
  if [ $? != 0 ]; then
    # Restore EVERY file this module's rewrite changed, not just the first; a restore that fails is
    # named, never dropped.
    rw_failed=''
    while IFS= read -r rw_f; do
      cp "$tmpd/orig/$rw_f" "$rw_f" 2>/dev/null && cmp -s "$tmpd/orig/$rw_f" "$rw_f" || rw_failed="$rw_failed $rw_f"
    done < "$tmpd/rw-changed"
    rw_err=$(printf '%s\n' "$rw_cout" 2>/dev/null | grep -m1 -E 'error')
    [ -n "$rw_err" ] || rw_err=$(first_line "$rw_cout")
    rw_note="$rw_note${rw_sep}--- purrism rewrite reverted in $rw_mod ---
$rw_mod did not compile with the rewrite of your changed lines, so it was undone — if the compile below passes, that was a purrism bug, not your code:
$rw_err"
    if [ -n "$rw_failed" ]; then
      rw_note="$rw_note
COULD NOT RESTORE the original of$rw_failed: the file still holds the rewrite that did not compile — restore it by hand."
    fi
    rw_sep='
'
    continue
  fi
  while IFS= read -r rw_f; do
    diff -u "$tmpd/orig/$rw_f" "$rw_f" | sed "1,2s#$tmpd/orig/##" >> "$tmpd/rw-diffs"
  done < "$tmpd/rw-changed"
  rw_mods="$rw_mods $rw_mod"
done < "$tmpd/rw-mods"

# The instruction goes BEFORE the diff: `block` bounds the message by bytes and cuts from the end, so a
# long diff may only ever lose diff lines, never the instruction the agent needs. It offers no
# `// scalafix:ok` escape: scalafix honours a suppression only for a patch its rule marks atomic, and in
# scalafix-purrism only KleisliScope does — measured, every suppression form left PreferOptionIdioms'
# rewrite applied, and the chain's whole-file `fix --check` blocks the original line regardless.
if [ -s "$tmpd/rw-diffs" ]; then
  block "purrism rewrote the lines you changed in$rw_mods.
Confirm the rewritten code still does what you meant, then end the turn again. If a rewrite is wrong,
do NOT merely revert it: the next turn-end reapplies it, and fix --check blocks the original anyway.
Instead restructure that code so the rule no longer matches, with a comment saying why, or
report the rule, the file:line and the reason to the human.
// scalafix:ok does not suppress most purrism rewrites. The rewrites:
$(bound_lines "$(cat "$tmpd/rw-diffs")" 60)"
fi

# The build-validity probe (F56) runs first: with a build script that will not compile, every module
# check after it fails for that one reason, and this is the output that says so.
if [ -s "$tmpd/mill" ]; then
  nchecks=$((nchecks + 1))
  probe_out=$("$mill" --ticker false --color false moduleMap 2>&1)
  probe_code=$?
  probe_before=$blocked
  classify "build validity probe: ./mill --ticker false moduleMap" "$probe_out" "$probe_code"
  if [ "$probe_code" = 0 ]; then
    probeline="build validity probe: ./mill --ticker false moduleMap passed (the touched .mill file still makes a build; this checks validity, not the task graph)."
  elif [ "$blocked" -gt "$probe_before" ]; then
    blockmods="$blockmods the build script (./mill --ticker false moduleMap)"
    remedies="$remedies
the build script: fix the .mill error(s) above — ./mill --ticker false moduleMap has to succeed again (this probe checks that the build parses and types; it does not check the task graph)."
  fi
fi

while IFS="$tab" read -r module caps; do
  [ -n "$module" ] || continue
  # `has_cap` is lib.sh's (M3): the same comma-delimited test post-edit asks of the same rows, and
  # `caps` is the loop variable here.
  remedy='fix the diagnostics above'
  if has_cap scalafix && has_cap fmt; then
    remedy="run ./mill $module.fix and ./mill $module.reformat"
  elif has_cap scalafix; then
    remedy="run ./mill $module.fix"
  elif has_cap fmt; then
    remedy="run ./mill $module.reformat"
  fi
  # A path under this module's own `test/` directory: that is the shape the `tests` token is written
  # in (`<id>.test.compile`), and `checkFormat`/`fix` cover the main sources only, so it is the test
  # submodule's compile that checks such a file. One test path in the module is enough to run it.
  moddir=$(awk -F"$tab" -v m="$module" '$2 == m { print $1; exit }' "$st/modules.tsv" 2>/dev/null)
  is_test=0
  while IFS="$tab" read -r _m _f; do
    [ "$_m" = "$module" ] || continue
    _rel=$_f
    case "$moddir" in
      ''|.) ;;
      *) _rel=${_f#"$moddir"/} ;;
    esac
    case "$_rel" in test/*) is_test=1; break ;; esac
  done < "$tmpd/modfiles"

  before=$blocked
  has_cap fmt && check "$module.checkFormat" "$module.checkFormat"
  has_cap scalafix && check "$module.fix --check" "$module.fix" --check
  has_cap scalafix && check "$module.fixStrict" "$module.fixStrict"
  check "$module.compile" "$module.compile"
  if [ "$is_test" = 1 ]; then
    has_cap tests && check "$module.test.compile" "$module.test.compile"
  fi
  if [ "$blocked" -gt "$before" ]; then
    blockmods="$blockmods $module"
    remedies="$remedies
$module: $remedy"
  fi
done < "$tmpd/mods"

# --- turnEndTests (spec 2026-09-20 §2) -----------------------------------------------------------
# The contract's full selection per touched module, through the wrapper. A red human-owned property
# or test BLOCKS the turn; a red DRAFT is noted. Modules run in order and stop at the first blocking
# one -- the Stop hook's budget is finite.
# The non-blocking verdict is EARNED, never defaulted: with rc != 0 the run is noted only when the
# render carries at least one `DRAFT ` record and no non-draft PROPERTY/TEST/INFRA/UNREADABLE record.
# A red run whose render is the FEEDBACK line alone (a green listing and then Mill fails; a parse gap
# the adapters do not cover) has no record to excuse it, so it blocks with the exit status.
# `fb_noted` counts these notes apart from `noted`: the F53 summary line speaks of checks that failed
# on files this turn did not touch, and a draft failure is not one of those.
te_stopped=0; te_left=0; te_greens=''; fb_noted=0
while IFS="$tab" read -r te_mod te_caps; do
  [ -n "$te_mod" ] || continue
  case ",$te_caps," in *,tests,*) ;; *) continue ;; esac
  te_cmd=$(dsh_contract_for_module turnEndTests "$te_mod" "$root") || continue
  if [ "$te_stopped" = 1 ]; then te_left=$((te_left + 1)); continue; fi
  te_out=$(sh "$here/hooks/feedback.sh" --selector "$te_mod.test" -- sh -c "$te_cmd" 2>&1); te_rc=$?
  if [ "$te_rc" = 0 ]; then te_greens="$te_greens
turnEndTests: $te_mod green"; continue; fi
  te_nondraft=$(printf '%s\n' "$te_out" | grep -Ec '^(PROPERTY|TEST|INFRA|UNREADABLE):')
  te_drafts=$(printf '%s\n' "$te_out" | grep -Ec '^DRAFT ')
  if [ "$te_nondraft" -gt 0 ]; then
    blocked=$((blocked + 1)); blockmods="$blockmods $te_mod"
    section blocking "turnEndTests: $te_mod (failed)" "$te_out"; te_stopped=1
  elif [ "$te_drafts" -gt 0 ]; then
    fb_noted=$((fb_noted + 1)); section note "turnEndTests: $te_mod ($te_drafts draft failure(s) — noted)" "$te_out"
  else
    blocked=$((blocked + 1)); blockmods="$blockmods $te_mod"
    section blocking "turnEndTests: $te_mod failed (exit $te_rc) with no failure records — see the log" "$te_out"; te_stopped=1
  fi
done < "$tmpd/mods"
[ "$te_left" -gt 0 ] && report="$report
$te_left modules not run — fix this one first"

# --- the verdict --------------------------------------------------------------------------------
if [ "$blocked" -gt 0 ]; then
  block "this turn left failing the commit gate:$blockmods
$report

Fix now:$remedies
Then re-read the changed files (annotated_source) before editing them again; this gate runs again when the turn ends."
fi

reset_counter
msg=''
add_line() {
  if [ -n "$msg" ]; then
    msg="$msg
$1"
  else
    msg="$1"
  fi
}
if [ -n "$ran" ]; then
  ran=${ran%, }
  add_line "DSH turn-end: no blocking findings for the files this turn touched."
  add_line "Ran, in this order: $ran"
fi
[ -n "$probeline" ] && add_line "$probeline"
[ -n "$vd_note" ] && add_line "$vd_note"
[ -n "$rw_note" ] && add_line "$rw_note"
if [ -n "$te_greens" ]; then
  while IFS= read -r te_gl; do
    [ -n "$te_gl" ] && add_line "$te_gl"
  done <<TE_GREENS
$te_greens
TE_GREENS
fi
scope_note=$(baseline_note)
if [ -n "$scope_note" ]; then add_line "$scope_note"; fi
# Two kinds of note, two sentences: the F53 line counts CHECKS that failed on untouched files, and a
# draft's red property (`fb_noted`) is neither a check of that kind nor about another file, so it is
# announced in its own words -- the F53 count stays truthful when only drafts failed.
if [ "$noted" -gt 0 ] || [ "$fb_noted" -gt 0 ]; then
  notes=$(bound_bytes "$notes" "$max_notes_bytes")
  if [ "$noted" -gt 0 ]; then
    add_line "DSH turn-end (F53): $noted of $nchecks checks failed on files this turn did not touch — noted, not blocking:"
  fi
  if [ "$fb_noted" -gt 0 ]; then
    add_line "DSH turn-end: turnEndTests noted $fb_noted module(s) with only DRAFT failures — noted, not blocking:"
  fi
  add_line "$notes"
  if [ "$noted" -gt 0 ]; then
    add_line "Those files were already in that state before this turn; fix them only if they are yours."
  fi
fi
# --- the holdout suite: run, filtered, logged ---------------------------------------------------------
# The contract's `holdout` command is the held-out suite the agent can neither read nor edit (a
# `sealed` entry). The gate runs it here, keeps the whole output in the sealed log, and tells the
# agent only how many passed and which NAMES failed -- an oracle it can act on but not memorise.
# It is a SIGNAL, not a block: exit stays 0; `prePush` (the human's gate) is where it blocks.
holdout_cmd=$(dsh_contract_get holdout "$root" 2>/dev/null) || holdout_cmd=''
if [ -n "$holdout_cmd" ]; then
  mkdir -p "$st" 2>/dev/null
  holdout_log="$st/holdout.log"
  ( cd "$root" && sh -c "$holdout_cmd" ) >"$holdout_log" 2>&1
  holdout_exit=$?
  holdout_report=$(dsh_weaver_failures <"$holdout_log")
  holdout_counts=$(printf '%s\n' "$holdout_report" | sed -n '1s/^holdout: \([0-9]*\) passed, \([0-9]*\) failed$/\1	\2/p')
  [ -n "$holdout_counts" ] || holdout_counts="-	-"
  # A run that did not complete (compile error, crash, a missing tool) leaves no result to read; the
  # exit status is the one fact this side may pass on -- the text stays in the sealed log. A weaver
  # run with failures ALSO exits non-zero, so the exit is reported only when the filter read nothing.
  if [ "$holdout_exit" != 0 ] && [ "$holdout_report" = "holdout: result unreadable" ]; then
    holdout_report="holdout: did not complete (exit $holdout_exit) — see the human's .dsh/.state/holdout.log"
  fi
  holdout_head=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || printf -- -)
  printf 'holdout\t%s\t%s\t%s\n' "$holdout_counts" "$holdout_head" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$st/receipts" 2>/dev/null || :
  add_line "$holdout_report"
  add_line "The holdout suite is sealed: the gate ran it, you read only the names above; the full output is the human's (.dsh/.state/holdout.log)."
  add_line "Unit tests are NOT run by this gate — ./mill prePush compiles and runs them. A green turn-end means the checks above passed, never that the suite did."
else
  add_line "Tests are NOT run by this gate — ./mill prePush compiles and runs them. A green turn-end means the checks above passed, never that the suite did."
fi
allow "$msg"
