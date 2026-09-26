#!/bin/sh
# One health probe per session, cached for every per-call gate: the read/write semantic guard
# denies Scala text operations only while .dsh/.state/health says `healthy=1`, and stands down
# loudly (with a reason) in every other case, so a session whose semantic MCP is not usable can
# still read and write its own sources. This is a SessionStart hook: it reports, it never
# blocks, so it always exits 0.
#
# The cached verdict is four lines:
#   healthy=0|1
#   checked=<ISO-8601 UTC>
#   reason=<why the verdict is what it is -- empty exactly when healthy=1>
#   notes=<what `doctor` said that did not decide the verdict, joined onto one line; may be
#          populated while healthy=1>
# The gates read `^healthy=1$` and nothing else; `reason` and `notes` are for the next reader.
#
# `notes` LEADS with the harness's own fact about the index -- `index covers 61 of 164 Scala sources
# (37%)` -- and only then carries doctor's FAIL lines: the coverage sentence is what tells the next
# reader how much of the tree the guard can actually answer for, and a noisy doctor must not be able
# to push it out of the field (both share the F47 caps, applied to the whole value). The same
# sentence is printed on the context line, and check-harness.sh reports it as a note of its own, so
# all three read one helper (lib.sh: dsh_coverage_sentence) and cannot drift apart on the number.
# `healthy` keeps its meaning: launcher executable AND an index exists. It is NOT "the index covers
# everything" -- per-file coverage is the read gate's question, answered at the file (F72).
#
# The launcher is resolved in this order, stated here because the first step is a test seam:
# SCALASEMANTIC_MCP_LAUNCHER (set by a fixture, or by a deployment that installs the tool
# elsewhere), then PATH, then the profile's install location
# /Users/viktorskalinins/.local/bin/scalasemantic-mcp. Like GATE_ROOT, the variable exists for
# the tests: it is the only hermetic way for a fixture to point at a stub, or at a path that
# does not exist, and so measure the stand-down verdict on a machine where the absolute path
# above happens to exist. Production sets neither variable and takes the resolved path.
# One consequence of the seam is worth naming: the probe checks that the launcher is an
# executable file, not that it is the right program, so an executable-but-useless launcher (say
# SCALASEMANTIC_MCP_LAUNCHER=/bin/echo) with an index present reports healthy=1 and the session
# runs in *enforcing* mode. That is ruled behaviour for a test seam, and it is not a dead end:
# the denial text carries the `# semantic-fallback: <reason>` marker that releases a read.
#
# `doctor` runs with no timeout of its own: POSIX sh has no portable one, and the bridge already
# bounds every hook invocation. A `doctor` that hangs is therefore cut off there, before the
# verdict is written -- on a first session the file is simply absent and each gate stands down,
# the safe direction for a probe that can only ever make a session stricter. A verdict from an
# earlier session would remain in place until this probe overwrites it.
#
# `notes` is bounded (F47): at most 10 FAIL lines and at most 2000 characters, then a
# `… truncated` marker, and at most 300 characters of it reach the context line. Session context
# is a shared resource and doctor is a foreign program.
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/lib.sh"

root=$(gate_root)
st=$(state_dir)
tmp=""

# --- the launcher -------------------------------------------------------------------------
# Resolved exactly as the header states: override, then PATH, then the profile path.
launcher=${SCALASEMANTIC_MCP_LAUNCHER:-}
if [ -z "$launcher" ]; then
  launcher=$(command -v scalasemantic-mcp 2>/dev/null) || launcher=""
  # A PATH hit that is not a regular file (a directory, a shell builtin name) is not the
  # launcher; prefer the profile's install path over trusting it.
  if [ -n "$launcher" ] && [ ! -f "$launcher" ]; then
    launcher=/Users/viktorskalinins/.local/bin/scalasemantic-mcp
  fi
fi
[ -n "$launcher" ] || launcher=/Users/viktorskalinins/.local/bin/scalasemantic-mcp

# --- the index ----------------------------------------------------------------------------
# Mill writes the index INSIDE its output dir (out/<module>/semanticDbData*.dest/classes/
# META-INF/semanticdb/*.semanticdb) and sbt writes target/scala-*/classes/META-INF/semanticdb/,
# so `out` and `target` must NOT be pruned: pruning a build output is the one mistake that makes
# this probe always find nothing and stand every Scala read open. The candidate pattern stays as
# general as that on purpose, so a layout this hook has not seen (scala-cli's .scala-build, a
# future build tool) keeps working.
#
# What is pruned is the harness's own tree. `.dsh` holds the fixtures -- every
# tests/cases/health-*/root/out/.../Foo.scala.semanticdb is a real file under the root in a
# checkout -- and on a fresh clone with no build output of its own those fixture files satisfied
# this oracle, so the probe reported healthy=1 citing a fixture as "an index", and the read gate
# then denied Scala reads with nothing behind them (F46). `.superpowers` (the SDD workspace) is
# pruned for the same reason: never a source of build output, always inside the root.
index=$(find "$root" \
  \( -name .dsh -o -name .superpowers -o -name .git -o -name node_modules \
     -o -name .worktrees -o -name website \) -prune -o \
  -path '*/META-INF/semanticdb/*.semanticdb' -print 2>/dev/null | head -n 1)

docfile=$(mktemp 2>/dev/null) || docfile=""
[ -n "$docfile" ] || docfile=${TMPDIR:-/tmp}/dsh-health-doc.$$
trap 'rm -f "$docfile" "$tmp"' 0

# --- the verdict --------------------------------------------------------------------------
# Healthy needs two things, both of them facts about this machine's filesystem: the launcher
# exists and is executable, and a SemanticDB index was actually emitted under the root.
healthy=0
reason=""
fix=""
notes=""
coverage=""
nnotes=0
notes_truncated=0
dcode=0
# Set on the healthy path below, where the reasons are named; on the unhealthy path this field is not
# printed at all (that line ends in `-- fix: <what to do>` instead).
doctor=""
max_note_lines=10
max_note_chars=2000
max_line_note_chars=300
truncated_marker='… truncated'

if [ ! -f "$launcher" ] || [ ! -x "$launcher" ]; then
  reason="launcher $launcher is missing or not executable"
  fix="install scalasemantic-mcp at that path; an index comes from ./mill core.compile"
elif [ -z "$index" ]; then
  reason="no SemanticDB index under $root -- run ./mill core.compile to emit one"
  fix="compile the project, then start a new session (the probe is cached per session)"
else
  # Coverage comes FIRST, before doctor is even asked (F72): how much of the tree the index answers
  # for is the harness's own measurement, the reason a session needs to know how far `healthy=1`
  # reaches, and seeding `notes` with it means the F47 caps below bound the whole field -- a doctor
  # that floods its FAIL lines cannot push the coverage sentence out of the durable record. The scan
  # shares the guard's cache (`.dsh/.state/index-coverage`), so whichever runs first pays for it.
  coverage=''
  dsh_coverage_scan "$root" "$st/index-coverage" >/dev/null 2>&1
  coverage=$(dsh_coverage_sentence "$root" "$st/index-coverage")
  notes=$coverage
  # `doctor` is consulted for what it SAYS, never for its exit code. Measured here (F42): in a
  # worktree with no .claude/ directory it EXITS 0 WHILE PRINTING THREE FAILs -- "guard hook
  # installed", "guard hook registered", "MCP server configured" -- because not installing the
  # guard is a documented "valid choice" of its own. Two of those three are about Claude Code's
  # configuration, whereas in DSH the semantic MCP comes from the profile's cordis.patch.yml
  # row, not from .mcp.json. So a probe keyed on the exit code (or on those FAILs) would mark
  # the guard unhealthy in exactly the configuration where it works and stand every Scala read
  # open -- the trap this branch exists to avoid. A FAIL that concerns Claude Code's own config
  # must NEVER by itself make the session unhealthy; every line containing FAIL becomes `notes`
  # (F43) -- recorded, deciding nothing -- including doctor's own FAIL about the index if it
  # disagrees with the file found above. Doctor's `SemanticDB index` line is deliberately not
  # parsed when it says ok: the file under out/ or target/ is the oracle, and doctor would only
  # restate it.
  "$launcher" doctor --project "$root" >"$docfile" 2>&1 || dcode=$?
  # A non-zero exit is a note too (F47): the verdict must not use it, and the record must not
  # lose it. It is seeded first, so the FAIL lines join onto it -- and it joins onto the coverage
  # sentence, which is why this appends rather than assigns.
  if [ "$dcode" != 0 ]; then
    if [ -z "$notes" ]; then notes="doctor exited $dcode, not counted"; else notes="$notes; doctor exited $dcode, not counted"; fi
  fi
  # `|| [ -n "$line" ]` so a last line without a trailing newline is not dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *FAIL*)
        # The line cap bites before the trim costs a process: nnotes counts only kept lines.
        if [ "$nnotes" -ge "$max_note_lines" ]; then
          notes_truncated=1
          continue
        fi
        note=$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -n "$note" ] || continue
        nnotes=$((nnotes + 1))
        if [ -z "$notes" ]; then notes="$note"; else notes="$notes; $note"; fi ;;
    esac
  done <"$docfile"
  # `notes` is one line by construction: the loop above consumes doctor's output line by line,
  # so a newline is a separator, never content, and each note is joined with `; `. The `tr`
  # deletes the two characters that could still split the four-line file if a future edit fed
  # raw output into this variable -- newline and carriage return -- so `notes=` cannot become a
  # fifth line or a hidden `reason=`.
  notes=$(printf '%s' "$notes" | tr -d '\n\015')
  # The character cap, with the marker kept inside the budget so the field itself stays bounded.
  if [ "${#notes}" -gt "$max_note_chars" ]; then
    notes_truncated=1
    notes=$(printf '%s' "$notes" | cut -c "1-$((max_note_chars - ${#truncated_marker} - 1))")
  fi
  if [ "$notes_truncated" = 1 ]; then
    notes="$notes $truncated_marker"
  fi
  healthy=1
fi

# What doctor contributed, for the context line only. F43: `reason` carries the verdict's reason
# and nothing else -- empty exactly when healthy=1 -- so the doctor material never lands there.
#
# There is no longer a "doctor: clean" case to report, and saying so IS the point: since F72 `notes=`
# always leads with the coverage sentence while healthy=1, so a "clean" branch would be reachable
# exactly never. Rather than leave a branch no reader can reach -- or a "clean" that never appears --
# the field states what the notes are and why they are non-empty. (`notes` can still be empty on the
# unhealthy path, where this field is not printed at all.)
if [ "$healthy" = 1 ]; then
  doctor="informational, not counted -- the notes field leads with the coverage sentence"
fi

# The same notes, cut again for the context line: the file keeps the durable record, the line
# gets a fixed share of a shared resource.
notes_line=$notes
if [ "${#notes_line}" -gt "$max_line_note_chars" ]; then
  notes_line=$(printf '%s' "$notes_line" | cut -c "1-$((max_line_note_chars - ${#truncated_marker} - 1))")
  notes_line="$notes_line $truncated_marker"
fi

# --- the cached verdict the gates read ----------------------------------------------------
# Written through a temp file in the same directory and renamed, because every per-call guard
# reads this file and must never see a half-written one.
mkdir -p "$st" 2>/dev/null
tmp="$st/.health.$$"
if { printf 'healthy=%s\n' "$healthy"
     printf 'checked=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
     printf 'reason=%s\n' "$reason"
     printf 'notes=%s\n' "$notes"
   } 2>/dev/null >"$tmp"; then
  # tmp is cleared only on success, so the trap removes a temp file that never made it here.
  if mv -f "$tmp" "$st/health" 2>/dev/null; then tmp=""; fi
else
  printf 'DSH harness: could not cache the verdict in %s/health\n' "$st" >&2
fi

# --- the session context line -------------------------------------------------------------
# One line, and it says which condition decided the verdict: on the healthy path the launcher,
# the index that was found and HOW MUCH of the tree that index answers for (the coverage
# sentence, stated in its own slot rather than only inside the notes echo -- how far `healthy=1`
# reaches is the fact a reader would otherwise have to reconstruct), on the stand-down path the
# reason plus what to do about it. Each line also echoes the cached fields verbatim (`reason=`
# empty means empty), so the reader sees why the session is where it is -- and a healthy line's
# doctor notes stay labelled as notes and after that verdict, never where a reason would go. Only
# `notes_line` (capped) is echoed here; the coverage sentence is short and fixed.
if [ "$healthy" = 1 ]; then
  printf 'DSH harness: semantic guard is active for %s -- launcher %s is executable and an index is present at %s; %s; health: healthy=%s reason=%s notes=%s; doctor: %s\n' \
    "$root" "$launcher" "$index" "$coverage" "$healthy" "$reason" "$notes_line" "$doctor"
else
  printf 'DSH harness: semantic guard stands down -- health: healthy=%s reason=%s notes=%s -- fix: %s\n' \
    "$healthy" "$reason" "$notes_line" "$fix"
fi

# --- the engine's own provenance and the build tool (spec 2026-09-26 §2, §3) -----------------------
# Printed as separate note lines, never folded into `notes=` (whose caps belong to doctor and coverage).
# Only a vendored engine has a stamp to compare; the template's own runs are not vendored.
eng=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if dsh_is_vendored_engine "$eng" "$root"; then
  sv=$(dsh_engine_stamp_verdict "$eng")
  [ "$sv" = ok ] || printf 'DSH harness: note -- vendored engine does not match its stamp (%s); run sh .dsh/engine/check-harness.sh\n' "$sv"
fi
if nm=$(dsh_non_mill_build "$root"); then
  printf 'DSH harness: note -- gate engine supports Mill builds only; found: %s -- checks stand down\n' "$nm"
fi
exit 0
