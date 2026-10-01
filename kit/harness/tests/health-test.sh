#!/bin/sh
# Direct tests for .dsh/engine/hooks/health.sh. Unlike tests/run.sh, which drives gate.sh through fixture
# case directories and can compare only an exit code and one grep of the hook's output, these run
# the hook and then read the file it writes, so the cached verdict's four-line shape and the
# invariants between its fields can be pinned on their own. The brief's `health-writes-verdict`
# case is this file: no case directory can assert on a file.
#
# Like tests/lib-test.sh, this file is deliberately NOT wired into tests/run.sh.
#
# The context-line assertions are built from the paths the line actually contains (fix round 3):
# the line is `fixed text + <root> + <index> + <launcher> + capped notes`, and the index contains
# the root, so its length is a function of the machine's temp directory. An absolute byte bound is
# a test that can fail while the hook is correct, so the bound is computed per root and the notes
# field is asserted directly instead.
#
# Run: .dsh/engine/tests/health-test.sh
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$engine" || exit 1
passed=0
failed=0

# What the hook controls: at most this much of `notes` may reach the context line.
note_cap=300
# What the hook does not control: the literal text around the fields on the healthy line, plus the
# coverage sentence the hook derives from the root's CONTENTS (which is why it is a constant here:
# every `with_index` root reports `index covers 1 of 2 Scala sources (50%)`). Measured at 260
# characters for the line shape this file asserts (the doctor clause states what the notes field is
# and why it is non-empty, which is longer than the "clean" it replaced), budgeted here as 270, plus
# 30 characters of slack for a wording change. Everything else on the line is a path, and the paths
# are known here.
literal_context_chars=270
line_slack=30
pad=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

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
# The caps are in BYTES (health.sh, via lib.sh's bound_bytes): `${#x}` counts bytes under dash and
# characters under bash, so measuring with it made the same output pass under sh and fail under dash.
byte_len() { printf '%s' "$1" | wc -c | tr -d ' '; }
at_most() { # at_most <name> <limit> <length>
  if [ "$3" -le "$2" ]; then
    ok "$1 ($3 <= $2)"
  else
    bad "$1: $3 exceeds $2"
  fi
}

scratch() { mktemp -d; }
long_root() { # long_root <extra segments> -- a root that many `pad` segments deeper
  lr=$(mktemp -d)
  i=1
  while [ "$i" -le "$1" ]; do
    lr="$lr/$pad"
    i=$((i + 1))
  done
  mkdir -p "$lr"
  printf '%s\n' "$lr"
}
# The layout Mill produces, for a root that HAS sources: one indexed (`A.scala`) and one not
# (`B.scala`), so every healthy verdict in this file reports `index covers 1 of 2 Scala sources
# (50%)` and the counts are asserted, not merely their shape. A semanticdb whose source does not
# exist is dropped by the scan (a deleted file cannot be read), which is why the two files matter.
with_index() { # with_index <root>
  mkdir -p "$1/out/mod/semanticDbData.dest/classes/META-INF/semanticdb/mod/src" "$1/mod/src"
  : > "$1/out/mod/semanticDbData.dest/classes/META-INF/semanticdb/mod/src/A.scala.semanticdb"
  : > "$1/mod/src/A.scala"
  : > "$1/mod/src/B.scala"
}
index_of() { printf '%s\n' "$1/out/mod/semanticDbData.dest/classes/META-INF/semanticdb/mod/src/A.scala.semanticdb"; }
coverage_sentence() { printf '%s\n' 'index covers 1 of 2 Scala sources (50%)'; }
stub_launcher="$engine/tests/bin/scalasemantic-mcp"
run_health() { # run_health <root> [KEY=VALUE ...] -- fills out/code and the parsed file fields
  run_root=$1
  shift
  out=$(env "$@" GATE_ROOT="$run_root" PATH="$engine/tests/bin:$PATH" \
        sh "$engine/hooks/health.sh" 2>&1)
  code=$?
  file="$run_root/.dsh/.state/health"
  line1=$(sed -n '1p' "$file" 2>/dev/null)
  line2=$(sed -n '2p' "$file" 2>/dev/null)
  line3=$(sed -n '3p' "$file" 2>/dev/null)
  line4=$(sed -n '4p' "$file" 2>/dev/null)
  lines=$(wc -l <"$file" 2>/dev/null | tr -d ' ')
  healthy=${line1#healthy=}
  reason=${line3#reason=}
  notes=${line4#notes=}
}
shape() { # shape <name> -- the four lines, in order, with a plausible timestamp
  is "$1: the verdict file has exactly four lines" "4" "$lines"
  case "$line1" in
    healthy=0|healthy=1) ok "$1: line 1 is healthy=0|1" ;;
    *) bad "$1: line 1 is healthy=0|1, got [$line1]" ;;
  esac
  if printf '%s' "$line2" | grep -Eq '^checked=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    ok "$1: line 2 is checked=<ISO-8601 UTC>"
  else
    bad "$1: line 2 is checked=<ISO-8601 UTC>, got [$line2]"
  fi
  case "$line3" in
    reason=*) ok "$1: line 3 is reason=" ;;
    *) bad "$1: line 3 is reason=, got [$line3]" ;;
  esac
  case "$line4" in
    notes=*) ok "$1: line 4 is notes=" ;;
    *) bad "$1: line 4 is notes=, got [$line4]" ;;
  esac
}
reason_iff_healthy() { # reason_iff_healthy <name> -- reason empty exactly when healthy=1
  if [ "$healthy" = 1 ]; then
    is "$2: reason is empty while healthy=1" "" "$reason"
  else
    case "$reason" in
      "") bad "$2: reason is empty while healthy=0" ;;
      *) ok "$2: reason is non-empty while healthy=0" ;;
    esac
  fi
}
hook_exits_zero() { is "$1: the hook exits 0" "0" "$code"; }
notes_portion() { # notes_portion <context line> -- the notes field as the line echoed it
  # The trailing sections are cut FIRST and the `notes=` value taken second, so a wording change in
  # what follows the field (the doctor clause names the notes field itself) cannot swallow the value
  # through the greedy `^.*notes=`.
  printf '%s' "$1" | sed -e 's/; doctor: .*$//' -e 's/ -- fix: .*$//' -e 's/^.*notes=//'
}
line_bound() { # line_bound <root> -- the largest healthy context line the hook may print for it
  lb_root=$1
  lb_index=$(index_of "$1")
  printf '%s\n' "$(( ${#lb_root} + ${#lb_index} + ${#stub_launcher} \
    + note_cap + literal_context_chars + line_slack ))"
}
bounded_context_line() { # bounded_context_line <name> <root> -- what the hook controls, bounded
  bc_name=$1
  bc_portion=$(notes_portion "$out")
  at_most "$bc_name: the notes echoed on the context line are capped" "$note_cap" "$(byte_len "$bc_portion")"
  has "$bc_name: the echoed notes carry the truncation marker" "truncated" "$bc_portion"
  # The line's own length: the root and the index (which contains the root) and the launcher path
  # are the machine's, the notes are the hook's, and the rest is this file's literal budget. An
  # absolute number here was a flaky red (800 bytes passed at a 63-char root and failed at 104).
  at_most "$bc_name: the printed line fits its paths plus the notes cap" "$(line_bound "$2")" "${#out}"
}

# --- a healthy root whose doctor prints FAILs: the two fields stay apart --------------------
a=$(scratch); with_index "$a"
run_health "$a" SCALASEMANTIC_STUB_DOCTOR_CC_FAILS=1
hook_exits_zero "healthy+FAILs"
shape "healthy+FAILs"
is "healthy+FAILs: healthy=1" "1" "$healthy"
reason_iff_healthy "healthy+FAILs" "healthy+FAILs"
has "healthy+FAILs: the FAIL text is in notes" "FAIL" "$notes"
lacks "healthy+FAILs: the FAIL text is not in reason" "FAIL" "$reason"
has "healthy+FAILs: the printed line says the guard is active" "semantic guard is active" "$out"
has "healthy+FAILs: the printed line shows the empty reason field behind the coverage sentence" \
  "healthy=1 reason= notes=$(coverage_sentence)" "$out"

# --- F72: the coverage sentence leads `notes`, and it is on the context line too -------------
# The numbers are the harness's own fact about the index, not doctor's; seeding notes with them is
# what keeps a noisy doctor from pushing them out of the durable record, and the line states them in
# their own slot as well as inside the notes echo.
has "healthy+FAILs: notes LEADS with the coverage sentence" "$(coverage_sentence); FAIL" "$notes"
has "healthy+FAILs: the context line states the coverage in its own slot" \
  "$(coverage_sentence); health:" "$out"
lacks "healthy+FAILs: the coverage text is not in reason" "index covers" "$reason"

# --- a healthy root whose doctor is quiet --------------------------------------------------
b=$(scratch); with_index "$b"
run_health "$b"
hook_exits_zero "healthy+quiet"
shape "healthy+quiet"
is "healthy+quiet: healthy=1" "1" "$healthy"
reason_iff_healthy "healthy+quiet" "healthy+quiet"
is "healthy+quiet: notes is exactly the coverage sentence (nothing else to report)" \
  "$(coverage_sentence)" "$notes"

# --- no index at all ----------------------------------------------------------------------
c=$(scratch)
run_health "$c"
hook_exits_zero "no index"
shape "no index"
is "no index: healthy=0" "0" "$healthy"
reason_iff_healthy "no index" "no index"
has "no index: reason names the compile step" "./mill core.compile" "$reason"
is "no index: notes is empty (doctor is not run)" "" "$notes"
has "no index: the printed line tells the reader to compile" "./mill core.compile" "$out"

# --- no launcher --------------------------------------------------------------------------
d=$(scratch); with_index "$d"
run_health "$d" SCALASEMANTIC_MCP_LAUNCHER=/nonexistent/health-test/scalasemantic-mcp
hook_exits_zero "no launcher"
shape "no launcher"
is "no launcher: healthy=0" "0" "$healthy"
reason_iff_healthy "no launcher" "no launcher"
has "no launcher: reason names the launcher path" \
  "launcher /nonexistent/health-test/scalasemantic-mcp is missing or not executable" "$reason"
is "no launcher: notes is empty" "" "$notes"

# --- doctor exits non-zero: recorded as a note, still not a criterion ----------------------
e=$(scratch); with_index "$e"
run_health "$e" SCALASEMANTIC_STUB_DOCTOR=1
hook_exits_zero "doctor exit 1"
is "doctor exit 1: still healthy=1" "1" "$healthy"
reason_iff_healthy "doctor exit 1" "doctor exit 1"
is "doctor exit 1: reason stays empty" "" "$reason"
has "doctor exit 1: the exit code is recorded in notes" "exited 1, not counted" "$notes"

# --- F46: an index-shaped file inside the harness's own trees is not an index ---------------
# Each pruned tree gets its own root so each prune is asserted on its own: were either prune
# missing, that root would report healthy=1 citing its fixture as "an index".
f=$(scratch)
mkdir -p "$f/.dsh/engine/tests/cases/health-healthy/root/out/mod/semanticDbData.dest/classes/META-INF/semanticdb"
: > "$f/.dsh/engine/tests/cases/health-healthy/root/out/mod/semanticDbData.dest/classes/META-INF/semanticdb/Foo.scala.semanticdb"
run_health "$f"
hook_exits_zero "F46 .dsh"
shape "F46 .dsh"
is "F46 .dsh: a fixture-shaped index under .dsh does not make the root healthy" "0" "$healthy"
reason_iff_healthy "F46 .dsh" "F46 .dsh"
has "F46 .dsh: the reason says no index" "no SemanticDB index under" "$reason"
lacks "F46 .dsh: the .dsh fixture path is not cited" "Foo.scala.semanticdb" "$out"

g=$(scratch)
mkdir -p "$g/.superpowers/sdd/x/out/mod/META-INF/semanticdb"
: > "$g/.superpowers/sdd/x/out/mod/META-INF/semanticdb/Bar.scala.semanticdb"
run_health "$g"
hook_exits_zero "F46 .superpowers"
shape "F46 .superpowers"
is "F46 .superpowers: a fixture-shaped index under .superpowers does not make the root healthy" \
  "0" "$healthy"
reason_iff_healthy "F46 .superpowers" "F46 .superpowers"
has "F46 .superpowers: the reason says no index" "no SemanticDB index under" "$reason"
lacks "F46 .superpowers: the .superpowers fixture path is not cited" "Bar.scala.semanticdb" "$out"

# --- F46 contrast: the same shape under the root's own build output IS an index ------------
h=$(scratch); with_index "$h"
run_health "$h"
hook_exits_zero "index under out/"
shape "index under out/"
is "index under out/: healthy=1" "1" "$healthy"
reason_iff_healthy "index under out/" "index under out/"
has "index under out/: the printed line cites the index" "an index is present at" "$out"
has "index under out/: the printed line cites the build output" "/out/mod/semanticDbData.dest/" "$out"
has "index under out/: the printed line reports the coverage" "$(coverage_sentence)" "$out"

# --- F72: the COVERAGE scan prunes the harness's own trees too ------------------------------
# The health oracle is not the only reader of the semanticdb tree any more: the coverage counts come
# from the same walk, so an index-shaped file under `.dsh`/`.superpowers` must not count as coverage
# either. This root is HEALTHY (a real index under out/), so the scan runs, and it also holds a
# source and an index for it inside each pruned tree: were either prune missing, the sentence would
# read `3 of 4 Scala sources (75%)` instead of `1 of 2 (50%)` -- one assertion over both prunes.
j=$(scratch); with_index "$j"
mkdir -p "$j/.dsh/out/mod/META-INF/semanticdb" "$j/.superpowers/out/mod/META-INF/semanticdb"
: > "$j/.dsh/out/mod/META-INF/semanticdb/Ghost.scala.semanticdb"
: > "$j/.dsh/Ghost.scala"
: > "$j/.superpowers/out/mod/META-INF/semanticdb/Phantom.scala.semanticdb"
: > "$j/.superpowers/Phantom.scala"
run_health "$j"
hook_exits_zero "coverage prunes .dsh and .superpowers"
shape "coverage prunes .dsh and .superpowers"
is "coverage prunes .dsh and .superpowers: healthy=1" "1" "$healthy"
is "coverage prunes .dsh and .superpowers: the indexed source inside a pruned tree is not coverage" \
  "$(coverage_sentence)" "$notes"
lacks "coverage prunes .dsh and .superpowers: the pruned sources are not counted" "of 4 Scala sources" "$out"

# --- F47: a doctor that repeats itself is capped ------------------------------------------
i=$(scratch); with_index "$i"
run_health "$i" SCALASEMANTIC_STUB_DOCTOR_MANY_FAILS=1
hook_exits_zero "many FAILs"
is "many FAILs: still healthy=1" "1" "$healthy"
reason_iff_healthy "many FAILs" "many FAILs"
is "many FAILs: reason stays empty" "" "$reason"
has "many FAILs: notes is marked truncated" "truncated" "$notes"
at_most "many FAILs: notes is capped" 2000 "$(byte_len "$notes")"
bounded_context_line "many FAILs" "$i"

# --- the context line's bound is a function of the paths, not of the machine's TMPDIR -------
# macOS's mktemp does not honour TMPDIR (measured: TMPDIR=<99-char dir> mktemp -d still returns a
# 63-char /var/folders path), so the roots are grown here by nesting instead: 0, 1, 2 and 3 pad
# segments, i.e. roughly 63, 104, 145 and 186 characters on this machine. The old absolute bound
# of 800 bytes passed at 63 characters and failed from 104 up, with the hook behaving correctly.
for segments in 0 1 2 3; do
  case $segments in
    0) root=$(scratch) ;;
    *) root=$(long_root "$segments") ;;
  esac
  seg_name="$segments pad segments ($(printf '%s' "$root" | wc -c | tr -d ' ') chars)"
  with_index "$root"
  run_health "$root" SCALASEMANTIC_STUB_DOCTOR_MANY_FAILS=1
  hook_exits_zero "$seg_name"
  is "$seg_name: healthy=1" "1" "$healthy"
  bounded_context_line "$seg_name" "$root"
  rm -rf "${root%%/$pad*}"
done

rm -rf "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$h" "$i" "$j"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
