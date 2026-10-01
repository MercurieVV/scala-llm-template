#!/bin/sh
# Direct tests for .dsh/engine/lib.sh and the gate.sh stand-down path. Unlike tests/run.sh, which
# drives gate.sh through fixture case directories, these call the helpers in-process, so the
# JSON backends, the root precedence and the no-reader path can each be pinned on their own.
#
# Run: .dsh/engine/tests/lib-test.sh
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$engine" || exit 1
passed=0
failed=0

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
is() { # is <name> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$2], got [$3]"; fi
}
has() { # has <name> <needle> <haystack> — for a multi-line result, where `is` would be unreadable
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1: [$2] not found in [$3]" ;;
  esac
}

# --- (a) every value shape renders identically through jq and through python3 ---------
# Each reader gets a PATH holding only itself, so the other one cannot be found.
GATE_PAYLOAD='{"s":"hello","bt":true,"bf":false,"n":42,"f":1.0,"nil":null,"o":{"a":1,"b":["x"]}}'
export GATE_PAYLOAD
jq_only=$(mktemp -d)
python_only=$(mktemp -d)
jq_bin=$(command -v jq) || jq_bin=""
python_bin=$(command -v python3) || python_bin=""
have_jq=0; have_py=0
[ -n "$jq_bin" ] && have_jq=1
[ -n "$python_bin" ] && have_py=1
# The gate needs ONE JSON reader, never both: `payload_get`, `payload_with_tool` and
# `gate_payload_verdict` each try jq and fall back to python3 (lib.sh). This block compares the two
# BACKENDS, which needs both — but a host with only one is a supported host, and exiting 1 there
# reported a broken installation on a machine where the harness works (M9). So: both -> the full
# comparison; one -> the same assertions against the reader that exists, with a note naming the one
# that is absent and what is therefore not compared; neither -> FAIL, because that host has no JSON
# reader at all and every hook would stand down.
if [ "$have_jq" = 0 ] && [ "$have_py" = 0 ]; then
  printf 'FAIL neither jq nor python3 is on PATH — the gate needs one JSON reader, and without either every hook stands down\n'
  exit 1
fi
[ "$have_jq" = 1 ] || printf 'note jq is not on PATH — payload_get/payload_with_tool are asserted through python3 only (python3 alone is a supported host)\n'
[ "$have_py" = 1 ] || printf 'note python3 is not on PATH — payload_get/payload_with_tool are asserted through jq only (jq alone is a supported host)\n'
[ "$have_jq" = 1 ] && ln -s "$jq_bin" "$jq_only/jq"
[ "$have_py" = 1 ] && ln -s "$python_bin" "$python_only/python3"

get() { PATH="$1" /bin/sh -c '. "$1/lib.sh"; payload_get "$2"' _ "$engine" "$2"; }
tool_with() { PATH="$1" /bin/sh -c '. "$1/lib.sh"; payload_with_tool "$2"' _ "$engine" "$2"; }
field() { # field <field> <want>
  [ "$have_jq" = 1 ] && is "jq      payload_get $1" "$2" "$(get "$jq_only" "$1")"
  [ "$have_py" = 1 ] && is "python3 payload_get $1" "$2" "$(get "$python_only" "$1")"
  return 0
}

field s hello
field bt true
field bf false
field n 42
field f 1.0
field nil ""
field o '{"a":1,"b":["x"]}'
field absent.deep.path ""

if [ "$have_jq" = 1 ] && [ "$have_py" = 1 ]; then
  is "payload_with_tool agrees across readers" "$(tool_with "$jq_only" write)" \
     "$(tool_with "$python_only" write)"
else
  printf 'note the cross-reader agreement of payload_with_tool is not compared: only one of jq/python3 is on PATH\n'
fi
# Asserted through whichever reader exists — with both, through jq (the `tool_with` line above has
# already proved the two agree, so this one is about the replacement itself).
if [ "$have_jq" = 1 ]; then
  is "payload_with_tool replaces tool_name" \
     '{"s":"hello","bt":true,"bf":false,"n":42,"f":1.0,"nil":null,"o":{"a":1,"b":["x"]},"tool_name":"write"}' \
     "$(tool_with "$jq_only" write)"
else
  is "payload_with_tool replaces tool_name" \
     '{"s":"hello","bt":true,"bf":false,"n":42,"f":1.0,"nil":null,"o":{"a":1,"b":["x"]},"tool_name":"write"}' \
     "$(tool_with "$python_only" write)"
fi

# --- (b) gate_root precedence: GATE_ROOT -> CLAUDE_PROJECT_DIR -> git -> PWD ----------
root() { # root <env args...> — gate_root in a child holding exactly these variables
  env "$@" /bin/sh -c '. "$1/lib.sh"; gate_root' _ "$engine"
}
is "GATE_ROOT beats CLAUDE_PROJECT_DIR" "/a" "$(root GATE_ROOT=/a CLAUDE_PROJECT_DIR=/b)"
is "CLAUDE_PROJECT_DIR without GATE_ROOT" "/b" "$(root -u GATE_ROOT CLAUDE_PROJECT_DIR=/b)"
is "git toplevel without either variable" "$(git rev-parse --show-toplevel)" "$(root -u GATE_ROOT -u CLAUDE_PROJECT_DIR)"
is "PWD outside any repository" "/" "$(cd / && root -u GATE_ROOT -u CLAUDE_PROJECT_DIR)"

# --- (c) with no JSON reader on PATH, gate.sh names the reason and stands down --------
no_reader=$(mktemp -d)
ln -s "$(command -v sh)" "$no_reader/sh"
ln -s "$(command -v dirname)" "$no_reader/dirname"
ln -s "$(command -v cat)" "$no_reader/cat"
out=$(env PATH="$no_reader" /bin/sh "$engine/gate.sh" semantic-guard \
      < "$engine/tests/cases/dispatch-noop/payload.json" 2>&1)
code=$?
is "gate.sh without a JSON reader exits 0" "0" "$code"
case "$out" in
  *"gate stands down"*) ok "gate.sh without a JSON reader says it stands down" ;;
  *) bad "gate.sh without a JSON reader says it stands down: got [$out]" ;;
esac
case "$out" in
  *"no JSON reader"*) ok "gate.sh without a JSON reader names the reason" ;;
  *) bad "gate.sh without a JSON reader names the reason: got [$out]" ;;
esac

# --- (d) the shared byte bound: one implementation, both hooks (F59) ------------------
# Each call is a child that has sourced lib.sh and nothing else, so the helper cannot pass by
# borrowing a variable from a hook — including the marker it appends, which must therefore be its
# own default. Bounds are in bytes, not characters and not lines: `cut -c` cuts per LINE, which is
# what made the old bound unbounded on a report of many long lines.
bound() { /bin/sh -c '. "$1/lib.sh"; bound_bytes "$2" "$3"' _ "$engine" "$1" "$2"; }
bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

short='hello, world'
is "bound_bytes keeps text under the bound" "$short" "$(bound "$short" 4000)"
is "bound_bytes keeps text exactly at the bound" "$short" "$(bound "$short" 12)"

# 200 bytes in, bound 40: the text keeps 40-16 bytes — the slack the marker and its space need — and
# the marker follows it, so 24 text bytes + ' ' + the 13-byte marker is 38 bytes out, inside the bound.
long=$(awk 'BEGIN { while (i++ < 200) printf "x" }')
want=$(awk 'BEGIN { while (i++ < 24) printf "x" }')" … truncated"
cut=$(bound "$long" 40)
is "bound_bytes cuts over-long text to the bound, in bytes" "$want" "$cut"
cut_size=$(bytes "$cut")
if [ "$cut_size" -le 40 ]; then
  ok "bound_bytes keeps the cut text inside the bound ($cut_size <= 40 bytes)"
else
  bad "bound_bytes keeps the cut text inside the bound: got $cut_size bytes"
fi

multiline=$(printf 'first\nsecond\nthird')
is "bound_bytes does not cut by line" "$multiline" "$(bound "$multiline" 4000)"

# The EPIPE noise Task 8's review found: with SIGPIPE ignored — the disposition a hook inherits in
# production — bash 3.2's printf reports `write error: Broken pipe` when `head -c` closes the pipe
# first, and that line would arrive ahead of the gate's own message. `2>/dev/null` on the printf is
# the fix; a payload larger than the pipe buffer is what makes the write fail mid-stream.
big=$(mktemp)
awk 'BEGIN { for (j = 0; j < 8000; j++) printf "line %d yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n", j }' > "$big"
epipe=$(/bin/sh -c 'trap "" PIPE; . "$1/lib.sh"; x=$(cat "$2"); bound_bytes "$x" 2000' \
        _ "$engine" "$big" 2>&1 >/dev/null)
is "bound_bytes writes no EPIPE noise while SIGPIPE is ignored" "" "$epipe"

# --- (e) the shared line bound and the file-name predicate (F62) -------------------------------
# Same shape as (d): a child that has sourced lib.sh only. F62 moved `bound_lines` and `names_file`
# out of the two hooks because they were byte-identical copies — and because BOTH copies of the
# `printf | head`/`printf | grep -q` pipeline had the EPIPE defect below.
lines() { /bin/sh -c '. "$1/lib.sh"; bound_lines "$2" "$3"' _ "$engine" "$1" "$2"; }
three=$(printf 'one\ntwo\nthree')
is "bound_lines keeps text under the bound" "$three" "$(lines "$three" 15)"
is "bound_lines keeps text exactly at the bound" "$three" "$(lines "$three" 3)"
five=$(printf 'one\ntwo\nthree\nfour\nfive')
is "bound_lines cuts over-long text to the bound" "$(printf 'one\ntwo\n… 3 more lines')" "$(lines "$five" 2)"

epipe_lines=$(/bin/sh -c 'trap "" PIPE; . "$1/lib.sh"; x=$(cat "$2"); bound_lines "$x" 3' \
              _ "$engine" "$big" 2>&1 >/dev/null)
is "bound_lines writes no EPIPE noise while SIGPIPE is ignored" "" "$epipe_lines"

named() { /bin/sh -c '. "$1/lib.sh"; if names_file "$2" "$3"; then printf yes; else printf no; fi' \
          _ "$engine" "$1" "$2"; }
is "names_file sees a scala diagnostic" "yes" "$(named 'error: A.scala:3:1: not found' 'scala|sc|java')"
is "names_file sees a mill diagnostic when the vocabulary has it" "yes" \
   "$(named '[error] build.mill:700:30' 'scala|sc|java|mill')"
is "names_file ignores .mill when the vocabulary does not have it" "no" \
   "$(named '[error] build.mill:700:30' 'scala|sc|java')"
is "names_file ignores .scalafmt.conf" "no" \
   "$(named 'parsed config (v3.10.7): /x/.scalafmt.conf' 'scala|sc|java')"
is "names_file ignores a .semanticdb sibling" "no" "$(named 'wrote A.scala.semanticdb' 'scala|sc|java')"

# The predicate's own EPIPE path: `grep -q` matches the FIRST line and exits, so the remaining
# ~500 KB of the printf is what fails when SIGPIPE is ignored.
bigmatch=$(mktemp)
{ printf 'error: A.scala:1:1\n'
  awk 'BEGIN { for (j = 0; j < 8000; j++) printf "line %d yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n", j }'
} > "$bigmatch"
epipe_names=$(/bin/sh -c 'trap "" PIPE; . "$1/lib.sh"; x=$(cat "$2"); names_file "$x" "scala|sc|java"' \
              _ "$engine" "$bigmatch" 2>&1 >/dev/null)
is "names_file writes no EPIPE noise while SIGPIPE is ignored" "" "$epipe_names"
rm -f "$big" "$bigmatch"

fl() { /bin/sh -c '. "$1/lib.sh"; first_line "$2"' _ "$engine" "$1"; }
is "first_line takes the first line without a pipe" "BLOCKED by the DSH gate: x" \
   "$(fl 'BLOCKED by the DSH gate: x
second line
third')"
is "first_line leaves a single-line text alone" "one line only" "$(fl 'one line only')"
is "first_line of an empty text is empty" "" "$(fl '')"

# --- (f) the session-baseline helpers (F61, F62) -----------------------------------------------
# `dsh_touched_files` is the one that mattered most: it is shared by both hooks, and the pre-F62
# version silently dropped every path git C-quotes. The six names below are exactly the ones that
# used to disappear (measured: two of them survived), so this assertion is the regression guard for
# that defect as well as a unit test of the helper.
key() { /bin/sh -c '. "$1/lib.sh"; dsh_state_key "$2"' _ "$engine" "$1"; }
is "dsh_state_key keeps a plain id" "s1" "$(key s1)"
# Dots are kept on purpose: the key is only ever a `baseline-<key>.tsv` NAME, so `..` cannot traverse
# out of the state directory, while `.` and `-` are common in session ids. Separators and spaces are
# not kept, which is what stops an id from steering the path at all.
is "dsh_state_key never lets an id steer a path" "a_b_c..d" "$(key 'a/b c..d')"
bfile=$(/bin/sh -c '. "$1/lib.sh"; GATE_ROOT=/tmp/x dsh_baseline_file s1' _ "$engine")
is "dsh_baseline_file is one file per session" "/tmp/x/.dsh/.state/baseline-s1.tsv" "$bfile"

hash_of() { /bin/sh -c '. "$1/lib.sh"; dsh_file_hash "$2"' _ "$engine" "$1"; }
hashed=$(mktemp); printf 'x\n' > "$hashed"
is "dsh_file_hash is a sha256 for a readable file" "64" "$(printf '%s' "$(hash_of "$hashed")" | wc -c | tr -d ' ')"
is "dsh_file_hash answers - for a missing file" "-" "$(hash_of "$hashed.nope")"

# Without a hasher the comparison is meaningless (`-` = `-` reads as "unchanged"), so the helper that
# says so has to be right: PATH holds nothing at all here, only shell builtins are used.
noh=$(PATH=/nonexistent /bin/sh -c '. "$1/lib.sh"; dsh_has_hasher; printf "%s" "$?"' _ "$engine")
is "dsh_has_hasher says no with no sha256 tool on PATH" "1" "$noh"
is "dsh_file_hash falls back to - with no sha256 tool" "-" \
   "$(PATH=/nonexistent /bin/sh -c '. "$1/lib.sh"; dsh_file_hash "$2"' _ "$engine" "$hashed")"

basefile=$(mktemp)
printf '# DSH session baseline s1 2026-01-01T00:00:00Z\n' > "$basefile"
printf -- '-\tgone/Deleted.scala\nabc123\tA.scala\n' >> "$basefile"
readable() { /bin/sh -c '. "$1/lib.sh"; if dsh_baseline_readable "$2"; then printf yes; else printf no; fi' \
             _ "$engine" "$1"; }
is "dsh_baseline_readable accepts a real record" "yes" "$(readable "$basefile")"
rows() { /bin/sh -c '. "$1/lib.sh"; dsh_baseline_rows "$2"' _ "$engine" "$1"; }
is "dsh_baseline_rows does not count the header" "2" "$(rows "$basefile")"
bhash() { /bin/sh -c '. "$1/lib.sh"; dsh_baseline_hash "$2" "$3"' _ "$engine" "$1" "$2"; }
is "dsh_baseline_hash reads a recorded hash" "abc123" "$(bhash "$basefile" A.scala)"
is "dsh_baseline_hash answers empty for a path that was clean at SessionStart" "" "$(bhash "$basefile" B.scala)"
garbage=$(mktemp); printf 'this file is not a baseline at all\n' > "$garbage"
is "dsh_baseline_readable refuses a foreign file" "no" "$(readable "$garbage")"
is "dsh_baseline_rows is 0 for a missing record" "0" "$(rows "$basefile.nope")"

# A real repository with dirty paths git cannot print literally, plus the shapes the filter must keep
# or drop: a non-Scala change, a deleted .scala (nothing to compile), a deleted .mill (a build
# change, still this gate's business).
touchrepo=$(mktemp -d)
tab=$(printf '\t')
( cd "$touchrepo" && git init -q . )
for n in 'A.scala' 'My File.scala' 'Back\slash.scala' 'Qu"ote.scala' "Tab${tab}Name.scala" 'é.scala' 'notes.md' 'Gone.scala' 'Build.mill' 'Move.mill'; do
  printf 'package x\n' > "$touchrepo/$n"
done
( cd "$touchrepo" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
for n in 'A.scala' 'My File.scala' 'Back\slash.scala' 'Qu"ote.scala' "Tab${tab}Name.scala" 'é.scala' 'notes.md'; do
  printf '\n// dirty\n' >> "$touchrepo/$n"
done
rm -f "$touchrepo/Gone.scala" "$touchrepo/Build.mill"
# A rename is not a change of two files: the vanished half must not be reported, for `.mill`
# exactly as for `.scala` — while a plain `.mill` DELETION still counts as a touched build file.
( cd "$touchrepo" && git mv Move.mill Moved.mill )
printf 'package x\n' > "$touchrepo/Newé.scala"
touched_out="$touchrepo.touched"
touch_code=$(/bin/sh -c '. "$1/lib.sh"; dsh_touched_files "$2" "$3"; printf "%s" "$?"' \
             _ "$engine" "$touchrepo" "$touched_out")
is "dsh_touched_files exits 0 on a readable tree" "0" "$touch_code"
has_line() { # has_line <name>
  if grep -qxF -- "$1" "$touched_out"; then ok "dsh_touched_files keeps $1"; else
    bad "dsh_touched_files keeps $1: got [$(tr '\n' ' ' < "$touched_out")]"
  fi
}
hasnt_line() {
  if grep -qxF -- "$1" "$touched_out"; then
    bad "dsh_touched_files drops $1: got [$(tr '\n' ' ' < "$touched_out")]"
  else ok "dsh_touched_files drops $1"; fi
}
has_line 'A.scala'
has_line 'My File.scala'
has_line 'Back\slash.scala'
has_line 'Qu"ote.scala'
has_line "Tab${tab}Name.scala"
has_line 'é.scala'
has_line 'Newé.scala'
has_line 'Build.mill'
has_line 'Moved.mill'
hasnt_line 'Move.mill'
hasnt_line 'notes.md'
hasnt_line 'Gone.scala'
# `dsh_changed_paths` is the same read UNFILTERED (spec 2026-09-28 §1, the post-hoc frozen check):
# every extension, a deletion, BOTH names of a rename, an untracked file, a non-ASCII name.
changed_out="$touchrepo.changed"
changed_code=$(/bin/sh -c '. "$1/lib.sh"; dsh_changed_paths "$2" "$3"; printf "%s" "$?"' \
               _ "$engine" "$touchrepo" "$changed_out")
is "dsh_changed_paths exits 0 on a readable tree" "0" "$changed_code"
for n in 'notes.md' 'Gone.scala' 'Build.mill' 'Move.mill' 'Moved.mill' 'Newé.scala' 'é.scala' "Tab${tab}Name.scala" 'A.scala'; do
  if grep -qxF -- "$n" "$changed_out"; then ok "dsh_changed_paths keeps $n"; else
    bad "dsh_changed_paths keeps $n: got [$(tr '\n' ' ' < "$changed_out")]"
  fi
done
is "dsh_changed_paths lists each path once" "$(sort -u "$changed_out" | wc -l | tr -d ' ')" "$(wc -l < "$changed_out" | tr -d ' ')"
is "dsh_changed_paths leaves no scratch files beside its output" "" \
   "$(ls "$touchrepo".changed.* 2>/dev/null)"
# `dsh_gate_written`: the ONE list of paths the gate itself writes during a session (fix round 1).
gw() { if /bin/sh -c '. "$1/lib.sh"; dsh_gate_written "$2" "$3"' _ "$engine" "$1" "${2:-}"; then printf yes; else printf no; fi; }
is "dsh_gate_written: receipts" "yes" "$(gw .dsh/.state/receipts)"
is "dsh_gate_written: ./-spelled receipts" "yes" "$(gw ./.dsh/.state/receipts)"
is "dsh_gate_written: modules.tsv" "yes" "$(gw .dsh/.state/modules.tsv)"
is "dsh_gate_written: a turn-end counter" "yes" "$(gw .dsh/.state/turn-end-s1.count)"
is "dsh_gate_written: a feedback log" "yes" "$(gw .dsh/.state/feedback/2026-09-28T00-00-00Z.log)"
is "dsh_gate_written: the human's machine-local frozen-paths is NOT the gate's" "no" "$(gw .dsh/.state/frozen-paths)"
is "dsh_gate_written: a project file is not" "no" "$(gw engine/details/A.scala)"
is "dsh_gate_written: another session's contract snapshot" "yes" "$(gw .dsh/.state/contracts/s2.tsv s1)"
is "dsh_gate_written: THIS session's contract snapshot is not (its baseline hash guards it)" "no" "$(gw .dsh/.state/contracts/s1.tsv s1)"
is "dsh_gate_written: THIS session's frozen record is not" "no" "$(gw .dsh/.state/frozen/s1.tsv s1)"
# The state key is cached per session id: a second id in the same shell must not reuse the first key.
is "dsh_gate_written: cached key follows a changed session id" "no-yes-no" \
   "$(/bin/sh -c '. "$1/lib.sh"; r=""; for a in "s1 s1" "s1 s2" "s2 s2"; do set -- $a; if dsh_gate_written ".dsh/.state/contracts/$1.tsv" "$2"; then r="$r-yes"; else r="$r-no"; fi; done; printf "%s" "${r#-}"' _ "$engine")"
# `dsh_frozen_match`: parse once, match many; same verdicts as `dsh_frozen_reason`.
fmroot=$(mktemp -d); mkdir -p "$fmroot/.dsh"
printf 'engine/details/**\tdir reason\nREADME.md\texact reason\nsealed\thold/\tsealed reason\n' > "$fmroot/.dsh/frozen-paths"
fm() { /bin/sh -c '. "$1/lib.sh"; r=$(dsh_frozen_paths "$2" 2>/dev/null); if dsh_frozen_match "$3" "$4" "$r"; then printf "%s" "$dsh_frozen_match_reason"; else printf "-"; fi' _ "$engine" "$fmroot" "$1" "$2"; }
is "dsh_frozen_match: prefix row" "dir reason" "$(fm any engine/details/X.scala)"
is "dsh_frozen_match: prefix row names the directory itself" "dir reason" "$(fm any engine/details)"
is "dsh_frozen_match: sibling with the prefix as a name prefix is not frozen" "-" "$(fm any engine/detailsX/A.scala)"
is "dsh_frozen_match: exact row" "exact reason" "$(fm any README.md)"
is "dsh_frozen_match: exact row does not match a child" "-" "$(fm any README.md/x)"
is "dsh_frozen_match: sealed row answers want=sealed" "sealed reason" "$(fm sealed hold/t.log)"
is "dsh_frozen_match: frozen row does not answer want=sealed" "-" "$(fm sealed README.md)"
is "dsh_frozen_match: no rows, no match" "-" "$(/bin/sh -c '. "$1/lib.sh"; if dsh_frozen_match any README.md ""; then printf y; else printf -- -; fi' _ "$engine")"
is "dsh_frozen_reason agrees with dsh_frozen_match" "dir reason" "$(/bin/sh -c '. "$1/lib.sh"; dsh_frozen_reason engine/details/X.scala "$2"' _ "$engine" "$fmroot")"
rm -rf "$fmroot"
# `dsh_frozen_ignored_files` (spec 2026-09-28 §1 item 2): the git-ignored files a frozen row answers
# for, minus the gate's own writes (`dsh_gate_written`, with the session id passed through).
firoot=$(mktemp -d)
( cd "$firoot" && git init -q . && mkdir -p .dsh/.state/contracts local/sub other \
  && printf 'local/\nother/\n.dsh/.state/\n' > .gitignore \
  && printf 'local/**\tlocal notes\ntracked.md\ttracked\nuntracked.md\tuntracked\n.dsh/.state/receipts\treceipts\n.dsh/.state/contracts/**\tsnapshots\n' > .dsh/frozen-paths \
  && printf t > tracked.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
  && printf u > untracked.md && printf a > local/a.txt && printf b > local/sub/b.txt && printf o > other/x.txt \
  && printf r > .dsh/.state/receipts && printf c1 > .dsh/.state/contracts/s1.tsv && printf c2 > .dsh/.state/contracts/s2.tsv ) >/dev/null 2>&1
fi_run() { /bin/sh -c '. "$1/lib.sh"; dsh_frozen_ignored_files "$2" "$3"; printf "rc=%s %s" "$?" "$dsh_frozen_ignored_reason"' _ "$engine" "$@"; }
is "dsh_frozen_ignored_files: with the session id, its own contract snapshot stays in" \
   "$(printf '.dsh/.state/contracts/s1.tsv\nlocal/a.txt\nlocal/sub/b.txt\nrc=0 ')" "$(fi_run "$firoot" s1)"
is "dsh_frozen_ignored_files: without one, every session's records stay out" \
   "$(printf 'local/a.txt\nlocal/sub/b.txt\nrc=0 ')" "$(fi_run "$firoot" '')"
fi_none=$(mktemp -d)
is "dsh_frozen_ignored_files: no frozen rows lists nothing" "rc=0 " "$(fi_run "$fi_none" s1)"
mkdir -p "$fi_none/.dsh" && printf 'a.txt\tx\n' > "$fi_none/.dsh/frozen-paths" && printf a > "$fi_none/a.txt"
has "dsh_frozen_ignored_files: git's answer failing is exit 1 with a reason, never 'nothing ignored'" \
    "rc=1 git check-ignore failed" "$(GIT_CEILING_DIRECTORIES="$fi_none" fi_run "$fi_none" s1)"
is "dsh_frozen_record_file: under .dsh/.state/frozen/, keyed like the other records" "$firoot/.dsh/.state/frozen/a_b.tsv" \
   "$(GATE_ROOT="$firoot" /bin/sh -c '. "$1/lib.sh"; dsh_frozen_record_file "a/b"' _ "$engine")"
fr_run() { /bin/sh -c '. "$1/lib.sh"; dsh_frozen_record_checks "$2"; printf "rc=%s" "$?"' _ "$engine" "$1"; }
has "dsh_frozen_record_checks: frozen rows without the records' row FAIL" \
    "FAIL	the frozen-path hash records (.dsh/.state/frozen/**) are not frozen — add the row to .dsh/frozen-paths" "$(fr_run "$firoot")"
has "dsh_frozen_record_checks: ... and exit 1" "rc=1" "$(fr_run "$firoot")"
printf '.dsh/.state/frozen/**\tthe frozen-path hash record is the human'"'"'s record of the frozen files at session start\n' >> "$firoot/.dsh/frozen-paths"
has "dsh_frozen_record_checks: with the row, ok" "ok	the frozen-path hash records" "$(fr_run "$firoot")"
has "dsh_frozen_record_checks: ... and exit 0" "rc=0" "$(fr_run "$firoot")"
rm -f "$fi_none/.dsh/frozen-paths"
is "dsh_frozen_record_checks: no frozen rows, nothing to say" "rc=0" "$(fr_run "$fi_none")"
rm -rf "$firoot" "$fi_none"
# `dsh_hash_files` (fix round 1, I1): one hasher run for many files, never a mis-attributed hash. Every
# row must equal the per-file `dsh_file_hash` of the same path; a file that cannot be hashed is absent.
hfroot=$(mktemp -d)
( cd "$hfroot" && mkdir -p 'd ir' && printf a > a.txt && printf b > 'd ir/with space.txt' \
  && printf c > 'back\slash.txt' && printf d > -dash.txt && printf e > 'two  spaces.txt' \
  && printf s > secret.txt && chmod 000 secret.txt )
printf '%s\n' a.txt 'd ir/with space.txt' 'back\slash.txt' -dash.txt 'two  spaces.txt' secret.txt gone.txt > "$hfroot.list"
hf_code=$(/bin/sh -c '. "$1/lib.sh"; dsh_hash_files "$2" "$3" "$4"; printf "%s" "$?"' _ "$engine" "$hfroot" "$hfroot.list" "$hfroot.out")
is "dsh_hash_files: exit 0" "0" "$hf_code"
for n in a.txt 'd ir/with space.txt' 'back\slash.txt' -dash.txt 'two  spaces.txt'; do
  hf_want=$(/bin/sh -c '. "$1/lib.sh"; h=$(dsh_file_hash "$2/$3"); printf "%s" "${h#\\}"' _ "$engine" "$hfroot" "$n")
  is "dsh_hash_files: $n hashed, and to its own hash" "$hf_want	$n" "$(grep -F -x -- "$hf_want	$n" "$hfroot.out")"
done
is "dsh_hash_files: an unreadable and a missing file are absent, not guessed" "5" "$(wc -l < "$hfroot.out" | tr -d ' ')"
is "dsh_hash_files: no scratch files beside its output" "" "$(ls "$hfroot".out.* 2>/dev/null)"
chmod 600 "$hfroot/secret.txt"; rm -rf "$hfroot" "$hfroot.list" "$hfroot.out"
# baseline.sh killed mid-hash (the SessionStart timeout) leaves no scratch directory behind (M1), under
# /bin/sh and under dash when present: dash skips an EXIT trap on a fatal signal unless one is set for it.
for kl_sh in /bin/sh dash; do
  command -v "$kl_sh" >/dev/null 2>&1 || continue
  klroot=$(mktemp -d); kltmp=$(mktemp -d); klbin=$(mktemp -d)
  ( cd "$klroot" && git init -q . && mkdir -p .dsh conf && printf 'conf/\n.dsh/.state/\n' > .gitignore \
    && printf 'conf/**\tconf\n' > .dsh/frozen-paths && git add -A && git -c user.email=t@t -c user.name=t commit -qm b \
    && printf x > conf/a ) >/dev/null 2>&1
  printf '#!/bin/sh\n: > "%s/reached"\nsleep 4\n' "$klbin" > "$klbin/shasum"; chmod +x "$klbin/shasum"
  printf '{"session_id":"k1"}' | TMPDIR="$kltmp" GATE_ROOT="$klroot" GATE_SH="$kl_sh" PATH="$klbin:$PATH" "$kl_sh" "$engine/gate.sh" baseline >/dev/null 2>&1 &
  klpid=$!
  kl_i=0; while [ ! -f "$klbin/reached" ] && [ "$kl_i" -lt 50 ]; do sleep 0.2; kl_i=$((kl_i + 1)); done
  is "baseline.sh kill test ($kl_sh): the hook reached the hasher" "yes" "$([ -f "$klbin/reached" ] && printf yes)"
  is "baseline.sh kill test ($kl_sh): its scratch directory exists while it hashes" "1" "$(ls -A "$kltmp" | wc -l | tr -d ' ')"
  kill -TERM "$klpid" 2>/dev/null; wait "$klpid" 2>/dev/null
  is "baseline.sh killed mid-hash ($kl_sh) leaves no scratch directory in TMPDIR" "" "$(ls -A "$kltmp")"
  sleep 4
  rm -rf "$klroot" "$kltmp" "$klbin"
done
# A read of the working tree that FAILS must not look like a clean tree: corruption of the index is
# the cheapest way to make `git status` error while the repository is still recognisable.
printf 'not an index at all' > "$touchrepo/.git/index"
fail_code=$(/bin/sh -c '. "$1/lib.sh"; dsh_touched_files "$2" "$3"; printf "%s" "$?"' \
            _ "$engine" "$touchrepo" "$touched_out")
is "dsh_touched_files exits 2 when git cannot read the tree" "2" "$fail_code"
fail_reason=$(/bin/sh -c '. "$1/lib.sh"; dsh_touched_files "$2" "$3" >/dev/null 2>&1; printf "%s" "$dsh_touched_reason"' \
              _ "$engine" "$touchrepo" "$touched_out")
case "$fail_reason" in
  *'git status'*failed*) ok "dsh_touched_files names the failed read: [$fail_reason]" ;;
  *) bad "dsh_touched_files names the failed read: got [$fail_reason]" ;;
esac
is "dsh_touched_files exits 1 outside a work tree" "1" \
   "$(GIT_CEILING_DIRECTORIES="$touchrepo" /bin/sh -c '. "$1/lib.sh"; dsh_touched_files "$2" "$3"; printf "%s" "$?"' _ "$engine" /nonexistent-dsh-root "$touched_out.none")"
is "dsh_changed_paths exits 2 when git cannot read the tree" "2" \
   "$(/bin/sh -c '. "$1/lib.sh"; dsh_changed_paths "$2" "$3"; printf "%s" "$?"' _ "$engine" "$touchrepo" "$changed_out")"
case "$(/bin/sh -c '. "$1/lib.sh"; dsh_changed_paths "$2" "$3" >/dev/null 2>&1; printf "%s" "$dsh_touched_reason"' _ "$engine" "$touchrepo" "$changed_out")" in
  *'git status'*failed*) ok "dsh_changed_paths names the failed read" ;;
  *) bad "dsh_changed_paths names the failed read" ;;
esac
is "dsh_changed_paths exits 1 outside a work tree" "1" \
   "$(GIT_CEILING_DIRECTORIES="$touchrepo" /bin/sh -c '. "$1/lib.sh"; dsh_changed_paths "$2" "$3"; printf "%s" "$?"' _ "$engine" /nonexistent-dsh-root "$changed_out.none")"
rm -rf "$touchrepo" "$touched_out" "$touched_out.none" "$changed_out" "$changed_out.none" "$hashed" "$basefile" "$garbage"

# --- (g) the EPIPE class, end to end through both long-message hooks (F62/F63) -----------------
# Five separate instances of this defect were found by five separate probes, so this section makes the
# CLASS testable rather than the instances: a hook is run with SIGPIPE ignored (the disposition it
# inherits in production) against a check whose diagnostics are far larger than a pipe buffer, and the
# two things that matter are asserted — stderr carries no `Broken pipe`, and its FIRST line is the
# verdict itself. Everything before this section tests helpers; this one tests what an agent would
# actually read.
#
# The size is the whole test, so here is the arithmetic. The message's report is built from
# `bound_lines`-bounded sections, so it can never exceed 15 LINES per failing check — adding lines
# cannot raise it. The padding therefore has to live inside a line: one ~60-byte path line plus 14
# padded lines. At 1,411-byte padding that is ~21 KB and the assertions pass vacuously (they did);
# at 5,000 bytes it is ~70 KB, which sits near the capacity and leaked only racy in the reviewer's
# runs; at 8,000 bytes it is ~112 KB, comfortably over the 64 KB pipe capacity, and the defect is
# deterministic (measured 5/5). The test uses 8,000 for that margin.
hooks_root=$(mktemp -d)
tab=$(printf '\t')
mkdir -p "$hooks_root/.dsh/.state" "$hooks_root/engine/details/src"
printf 'engine/details%sengine.details%sfmt\n' "$tab" "$tab" > "$hooks_root/.dsh/.state/modules.tsv"
printf 'package x\nobject A { val a = 1 }\n' > "$hooks_root/engine/details/src/A.scala"
cat > "$hooks_root/mill" <<'STUB'
#!/bin/sh
printf 'mill %s\n' "$*" >> "${MILL_STUB_LOG:-/dev/null}"
case "$*" in
  *checkFormat*)
    printf '%s/engine/details/src/A.scala\n' "$(pwd)"
    # 25 lines of 8 KB each: the bound keeps the first 15, so the writer is ~112 KB into a 64 KB
    # pipe when `head` has gone. Below the capacity the whole class stays silent, which is how it
    # went unnoticed four times; see the arithmetic in this section's header.
    awk 'BEGIN { s = sprintf("%8000s", ""); gsub(/ /, "y", s); for (i = 1; i <= 25; i++) printf "misformatted %d %s\n", i, s }'
    exit 1 ;;
esac
exit 0
STUB
chmod +x "$hooks_root/mill"
( cd "$hooks_root" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base ) >/dev/null 2>&1
printf '\n// touched by this turn\n' >> "$hooks_root/engine/details/src/A.scala"
printf '{"tool_name":"edit","tool_input":{"file_path":"engine/details/src/A.scala"}}' > "$hooks_root/post-edit.json"
printf '{"session_id":"epipe","hook_event_name":"Stop"}' > "$hooks_root/turn-end.json"
hooks_log="$hooks_root/mill.log"

# The hook is run by a shell that has SIGPIPE ignored, so the disposition reaches it and the shell's
# EXIT trap keeps a failed pipeline subshell alive to report the broken pipe instead of dying on it.
run_hook_ignoring_pipe() { # <subcommand> <payload-file> <stderr-file>
  : > "$hooks_log"
  /bin/sh -c 'trap "" PIPE
    GATE_ROOT="$1" PATH="$2/tests/bin:$PATH" MILL_STUB_LOG="$3" sh "$2/gate.sh" "$4" < "$5" 2>"$6" >/dev/null
    exit $?' _ "$hooks_root" "$engine" "$hooks_log" "$1" "$2" "$3"
}

for hook in post-edit turn-end; do
  err="$hooks_root/$hook.stderr"
  run_hook_ignoring_pipe "$hook" "$hooks_root/$hook.json" "$err"
  code=$?
  is "$hook blocks on the oversized report" "2" "$code"
  case "$(cat "$err" 2>/dev/null)" in
    *'Broken pipe'*)
      bad "$hook: stderr carries no Broken pipe: [$(head -n 1 "$err")]" ;;
    *) ok "$hook: stderr carries no Broken pipe" ;;
  esac
  case "$(head -n 1 "$err" 2>/dev/null)" in
    'BLOCKED by the DSH gate:'*)
      ok "$hook: the verdict is the first line of stderr" ;;
    *) bad "$hook: the verdict is the first line of stderr: got [$(head -n 1 "$err" 2>/dev/null)]" ;;
  esac
  err_bytes=$(wc -c < "$err" | tr -d ' ')
  if [ "$err_bytes" -le 8000 ]; then
    ok "$hook: the report stays bounded ($err_bytes bytes)"
  else
    bad "$hook: the report stays bounded: got $err_bytes bytes"
  fi
done

# M2 residual: a GREEN turn whose state directory cannot be written must not leak the shell's
# `Permission denied` for the counter it tried to reset. Nothing is reported on that path at all.
( cd "$hooks_root" && git checkout -q -- . )
chmod 500 "$hooks_root/.dsh/.state"
err="$hooks_root/green.stderr"
run_hook_ignoring_pipe turn-end "$hooks_root/turn-end.json" "$err"
green_err=$(cat "$err" 2>/dev/null)
chmod 700 "$hooks_root/.dsh/.state"
is "a green turn with an unwritable state dir says nothing on stderr" "" "$green_err"
rm -rf "$hooks_root"

# The class as a lint, so the next instance cannot hide in a hook the runtime test does not drive: a
# pipeline whose reader can exit before it has consumed everything is a `printf` that can report a
# broken pipe, and every one of them silences its writer. The alternation covers every early-exit
# reader this family has met or could meet: `head`, a bare `read`, `grep -q` in any bundling
# (`grep -[A-Za-z]*q` matches `-q`, `-Eq`, `-qxE`, `-qF`), `grep -m`/`--max-count`, a `sed` script
# with a `q` command, and an `awk` with an `exit`. Readers that consume all of their input (`wc`,
# `tr`, `cut`, `sort`, `cat`, `jq`, `python3`, plain `sed`) are not hazards and are not listed.
#
# What this lint CANNOT see is a pipeline whose writer is not a literal `printf` — a function's
# output piped into a reader. That shape existed in tool-policy.sh and is now structurally gone (a
# `case` test instead of the pipe); the report records the manual audit of every remaining
# non-`printf` writer in the family.
hazard=$(grep -nE 'printf [^|]*\| *(head|read|grep -[A-Za-z]*q|grep --?m|sed[^|]*q|awk[^|]*exit)' \
           "$engine/lib.sh" "$engine"/hooks/*.sh 2>/dev/null \
         | grep -v '2>/dev/null' | grep -v '^[^:]*:[0-9]*: *#' | head -5)
if [ -z "$hazard" ]; then
  ok "no unsuppressed printf pipeline whose reader can exit early"
else
  bad "no unsuppressed printf pipeline whose reader can exit early: $hazard"
fi

# --- (h) the report plumbing both Mill-running gates share (M3) ---------------------------------
# `section` was byte-identical in post-edit.sh and turn-end.sh, `has_cap` was the same logic in both,
# and the Mill resolution was the same rule with two spellings of the wrapper test. All three live in
# lib.sh now, and they are asserted here for the reason the bounds above are: a shared helper no test
# names is a helper that can be broken in both gates at once, silently.
sect() { # sect <long body> <short body>: what the two gates' report/notes look like after two sections
  /bin/sh -c '. "$1/lib.sh"
report=""; notes=""; max_lines=2
section blocking "One" "$2"
section note "Two" "$3"
printf "report=[%s]\nnotes=[%s]\n" "$report" "$notes"' _ "$engine" "$1" "$2"
}
body=$(printf 'l1\nl2\nl3')
sectout=$(sect "$body" 'a plain note')
has "section files a blocking body under report" "report=[
--- One ---
l1
l2
… 1 more lines]" "$sectout"
has "section files a note under notes, not under report" "notes=[
--- Two ---
a plain note]" "$sectout"
case "$sectout" in
  *"l3"*) bad "section cuts each body to the caller's max_lines: the third line survived a max_lines of 2" ;;
  *) ok "section cuts each body to the caller's max_lines" ;;
esac
has "section says so when a check printed nothing" "(the check printed nothing)" \
    "$(sect "$body" '')"

capq() { # capq <caps> <capability> -> yes|no
  /bin/sh -c '. "$1/lib.sh"; caps=$2; if has_cap "$3"; then printf yes; else printf no; fi' \
    _ "$engine" "$1" "$2"
}
is "has_cap finds the first token of a row" "yes" "$(capq 'fmt,scalafix,tests' fmt)"
is "has_cap finds a middle token of a row" "yes" "$(capq 'fmt,scalafix,tests' scalafix)"
is "has_cap finds the last token of a row" "yes" "$(capq 'fmt,scalafix,tests' tests)"
is "has_cap does not match a token's prefix" "no" "$(capq 'fmt,scalafix,tests' test)"
is "has_cap does not match a substring of a token" "no" "$(capq 'fixfmt,scalafix' fmt)"
is "has_cap does not match a superset of a token" "no" "$(capq 'tests' test)"
is "has_cap on a compile-only row (empty capability column)" "no" "$(capq '' fmt)"
is "has_cap on a row whose only token is scalafix" "no" "$(capq 'scalafix' fmt)"

# resolve_mill <root>: the wrapper when it is an executable FILE, else a `mill` on PATH, else
# nothing — which is what makes each gate deny with its own wording instead of checking nothing.
# The PATH is handed to the child in full, so the fallback is real and the "neither" case is a PATH
# with no mill in it at all.
mill_of() { # mill_of <root> <path> -> the resolved command, or NONE
  # The child's $1 is the repository (for lib.sh) and $2 is the root being resolved; the PATH
  # prefix is what the fallback searches, and in the "neither" case it holds no mill at all.
  PATH="$2" /bin/sh -c '. "$1/lib.sh"; resolve_mill "$2" || printf NONE' _ "$engine" "$1"
}
mroot=$(mktemp -d)
mkdir -p "$mroot/wrapped" "$mroot/bare" "$mroot/pathbin" "$mroot/emptybin"
printf '#!/bin/sh\nexit 0\n' > "$mroot/wrapped/mill"
chmod +x "$mroot/wrapped/mill"
printf '#!/bin/sh\nexit 0\n' > "$mroot/bare/mill"        # present, but NOT executable
printf '#!/bin/sh\nexit 0\n' > "$mroot/pathbin/mill"
chmod +x "$mroot/pathbin/mill"
is "resolve_mill prefers the repository's own executable wrapper" "./mill" \
   "$(mill_of "$mroot/wrapped" "$mroot/pathbin")"
is "resolve_mill falls back to a mill on PATH when the wrapper is not executable" "$mroot/pathbin/mill" \
   "$(mill_of "$mroot/bare" "$mroot/pathbin")"
is "resolve_mill answers nothing when there is neither (the caller fails closed)" "NONE" \
   "$(mill_of "$mroot/bare" "$mroot/emptybin")"
rm -rf "$mroot"

# --- (i) the per-file coverage helpers (F72) -----------------------------------------------------
# The read gate, the health probe and check-harness.sh all ask the same question -- which sources does
# the index actually cover -- and they ask it through these helpers, so what they agree on is pinned
# here rather than inferred from three call sites. The root is synthetic and hermetic: no Mill, no
# repository, no network. What each block protects:
#   * the COVERED SET is the index's own filenames mapped back to source paths, and a pair exists only
#     while its source does -- a stale index from a renamed file must not inflate the count and make
#     the guard deny a read of a file nothing covers;
#   * the harness's own trees are pruned exactly as the health oracle prunes them (F46), and build
#     output is pruned from the SOURCE count while the index itself lives under `out/` and is found;
#   * the CACHE cannot outlive its index in either direction: a pair appearing (even with an OLD
#     mtime), a pair disappearing, and an entry whose index file is gone all change the answer, while
#     an unchanged tree does not rewrite the cache at all;
#   * a cache that does not validate -- truncated, foreign, malformed rows, wrong declared count -- is
#     a MISS, never a "nothing is covered" that would stand a covered read down;
#   * PATH SPELLINGS are canonicalised before the lookup, because the index keys one spelling per
#     source and a command line may reach the same file another way.

covroot=$(mktemp -d)
# Sourced here, once, for this section only: the coverage helpers are pure functions of a root and a
# cache path, so calling them in-process asserts exactly what the guard calls -- and it is how
# check-harness.sh consumes them too (it sources lib.sh and hands them a scratch cache). The rest of
# this file goes through child shells for PATH isolation, which nothing here needs.
. "$engine/lib.sh"
coverage_count_child() { # coverage_count_child <cache>
  /bin/sh -c '. "$1/lib.sh"; dsh_coverage_count "$2"' _ "$engine" "$1"
}
covcache="$covroot/index-coverage"
covidx="$covroot/out/core/semanticDbData.dest/classes/META-INF/semanticdb/core/src"
covidx2="$covroot/out/core/semanticDbData.dest/data/META-INF/semanticdb/core/src"
mkdir -p "$covroot/core/src" "$covidx" "$covidx2" "$covroot/out/core/generated" "$covroot/target/gen"
: > "$covroot/core/src/A.scala"          # indexed, TWICE (classes/ and data/, as Mill writes it)
: > "$covroot/core/src/B.scala"          # NOT indexed
: > "$covroot/core/src/A.scala.bak"      # not a source; must not be covered by A.scala either
: > "$covidx/A.scala.semanticdb"
: > "$covidx2/A.scala.semanticdb"
: > "$covidx/Gone.scala.semanticdb"      # indexed, source deleted: not coverage
: > "$covroot/out/core/generated/Gen.scala"    # generated into build output: not a source
: > "$covroot/target/gen/Gen2.scala"
# The harness's own trees: an index-shaped file and its source inside each, which the F46 prune must
# keep out of both the covered set and the source count.
for pruned in .dsh .superpowers; do
  mkdir -p "$covroot/$pruned/out/mod/META-INF/semanticdb"
  : > "$covroot/$pruned/out/mod/META-INF/semanticdb/Ghost.scala.semanticdb"
  : > "$covroot/$pruned/Ghost.scala"
done

dsh_coverage_scan "$covroot" "$covcache"
is "coverage: the pairs the cache lists are the index's own filenames" \
  "core/src/A.scala	out/core/semanticDbData.dest/classes/META-INF/semanticdb/core/src/A.scala.semanticdb
core/src/A.scala	out/core/semanticDbData.dest/data/META-INF/semanticdb/core/src/A.scala.semanticdb" \
  "$(sed -n '2,$p' "$covcache")"
is "coverage: the header declares the row count, the distinct sources and a fingerprint" \
  "2 1" "$(dsh_coverage_header_field "$covcache" rows) $(dsh_coverage_header_field "$covcache" covered)"
case "$(dsh_coverage_header_field "$covcache" index)" in
  ''|none) bad "coverage: the header carries no index fingerprint: [$(head -n 1 "$covcache")]" ;;
  *) ok "coverage: the header carries an index fingerprint" ;;
esac
is "coverage: one source with two index files is ONE covered source" "1" "$(dsh_coverage_count "$covcache")"
is "coverage: the source count excludes build output and the harness's own trees" "2" \
  "$(dsh_scala_source_count "$covroot")"
is "coverage: the sentence carries both counts and the percentage" \
  "index covers 1 of 2 Scala sources (50%)" "$(dsh_coverage_sentence "$covroot" "$covcache")"
dsh_coverage_covers "$covroot" "$covcache" core/src/A.scala \
  && ok "coverage: covers() finds an indexed path" \
  || bad "coverage: covers() does not find an indexed path"
dsh_coverage_covers "$covroot" "$covcache" core/src/B.scala \
  && bad "coverage: covers() accepts an unindexed path" \
  || ok "coverage: covers() refuses an unindexed path"
dsh_coverage_covers "$covroot" "$covcache" core/src/A.scala.bak \
  && bad "coverage: covers() matches a prefix of a covered path" \
  || ok "coverage: covers() is an exact path, not a prefix"
dsh_coverage_covers "$covroot" "$covcache" core/src/Gone.scala \
  && bad "coverage: covers() accepts an index entry whose source no longer exists" \
  || ok "coverage: covers() refuses a deleted source's stale index entry"
dsh_coverage_covers "$covroot" "$covcache" .dsh/Ghost.scala \
  && bad "coverage: covers() counts an index-shaped file inside .dsh" \
  || ok "coverage: covers() prunes the harness's own trees (F46)"
# The per-entry half of the invalidation rule: a cache row whose own index file is gone is not
# coverage, whatever the cache says. Asserted on a hand-written v2 cache, because a SCAN can never
# produce this state (the fingerprint would have rebuilt it) -- this is the race the test closes.
covstale="$covroot/handmade"
{
  printf '# DSH index coverage v2 rows=1 covered=1 index=0-0\n'
  printf 'core/src/A.scala\tout/core/semanticDbData.dest/classes/META-INF/semanticdb/core/src/A.scala.semanticdb\n'
} > "$covstale"
dsh_coverage_covers "$covroot" "$covstale" core/src/A.scala \
  && ok "coverage: covers() accepts an entry whose index file exists" \
  || bad "coverage: covers() refuses an entry whose index file exists"
rm -f "$covidx/A.scala.semanticdb"
dsh_coverage_covers "$covroot" "$covstale" core/src/A.scala \
  && bad "coverage: covers() accepted an entry whose index file is gone" \
  || ok "coverage: covers() refuses an entry whose index file is gone (the clean case)"
: > "$covidx/A.scala.semanticdb"

# The cache is left alone while the index tree is unchanged...
before=$(dsh_file_hash "$covcache")
dsh_coverage_scan "$covroot" "$covcache"
is "coverage: an unchanged tree does not rewrite the cache" "$before" "$(dsh_file_hash "$covcache")"
# ...and is rebuilt in BOTH directions. Upward: B.scala gains an index.
: > "$covidx/B.scala.semanticdb"
dsh_coverage_scan "$covroot" "$covcache"
dsh_coverage_covers "$covroot" "$covcache" core/src/B.scala \
  && ok "coverage: a new index file refreshes the cache" \
  || bad "coverage: the cache was not refreshed by a new index file"
is "coverage: the refreshed sentence moves with it" \
  "index covers 2 of 2 Scala sources (100%)" "$(dsh_coverage_sentence "$covroot" "$covcache")"
# Downward, and this is the direction an mtime comparison cannot see: an index restored with an OLD
# mtime still changes the set of pairs, so the cache is rebuilt and the source counts as covered.
rm -f "$covidx/B.scala.semanticdb"
dsh_coverage_scan "$covroot" "$covcache"
dsh_coverage_covers "$covroot" "$covcache" core/src/B.scala \
  && bad "coverage: a removed index file did not invalidate the cache" \
  || ok "coverage: a removed index file invalidates the cache"
: > "$covidx/B.scala.semanticdb"
touch -t 202001010000 "$covidx/B.scala.semanticdb"
dsh_coverage_scan "$covroot" "$covcache"
dsh_coverage_covers "$covroot" "$covcache" core/src/B.scala \
  && ok "coverage: an index restored with an OLDER mtime than the cache still counts" \
  || bad "coverage: an older restored index did not invalidate the cache (the permissive direction)"

# A cache that does not validate is a miss. Each shape is written by hand, because a scan only ever
# produces a good one, and a bad one must never be read as "nothing is covered".
covbad="$covroot/bad"
bad_cache() { # bad_cache <name> <line1> <line2...>
  bc_name=$1; shift
  { for bc_line in "$@"; do printf '%s\n' "$bc_line"; done; } > "$covbad"
  if dsh_coverage_cache_valid "$covbad"; then
    bad "coverage: the cache validator accepts $bc_name"
  else
    ok "coverage: the cache validator rejects $bc_name"
  fi
}
bad_cache 'a truncated cache (header declares rows it no longer has)' \
  '# DSH index coverage v2 rows=1 covered=1 index=0-0'
bad_cache 'a cache with no header at all' \
  'core/src/A.scala	out/x/A.scala.semanticdb'
bad_cache 'a v1 header from the previous format' \
  '# DSH index coverage v1 -- covered source paths, one per line'
bad_cache 'a row with one field' \
  '# DSH index coverage v2 rows=1 covered=1 index=0-0' 'core/src/A.scala'
bad_cache 'a row whose index path is not a semanticdb' \
  '# DSH index coverage v2 rows=1 covered=1 index=0-0' 'core/src/A.scala	out/x/A.scala.txt'
bad_cache 'a row whose source is not a Scala source' \
  '# DSH index coverage v2 rows=1 covered=1 index=0-0' 'core/src/A.md	out/x/A.md.semanticdb'
bad_cache 'a header with no fingerprint' \
  '# DSH index coverage v2 rows=0 covered=0' ''
is "coverage: the validator accepts a good cache" "$(dsh_coverage_cache_valid "$covcache" && echo ok)" "ok"
is "coverage: the validator rejects a missing cache" \
  "$(dsh_coverage_cache_valid "$covroot/absent" && echo ok)" ""
# A cache the validator rejects is rebuilt by the next scan, so the covered read is still denied.
dsh_coverage_scan "$covroot" "$covcache"
head -n 1 "$covcache" > "$covbad"
mv -f "$covbad" "$covcache"
dsh_coverage_scan "$covroot" "$covcache"
dsh_coverage_covers "$covroot" "$covcache" core/src/A.scala \
  && ok "coverage: a truncated cache is rebuilt rather than believed" \
  || bad "coverage: a truncated cache was believed (the permissive direction)"

# PATH SPELLINGS. Every one of these names the same file as the index does, so every one of them must
# be found -- a spelling that is not found stands a covered read down, which is the permissive
# direction this rule must never drift in.
canon() { # canon <path> -> the canonical spelling
  /bin/sh -c '. "$1/lib.sh"; dsh_canonical_path "$2"' _ "$engine" "$1"
}
is "canonical: a leading ./ is dropped" "a/b" "$(canon './a/b')"
is "canonical: // collapses" "a/b" "$(canon 'a//b')"
is "canonical: . segments are dropped" "a/b/c" "$(canon 'a/./b/c')"
is "canonical: .. pops the previous segment" "a/c" "$(canon 'a/b/../c')"
is "canonical: .. above the root of an absolute path is the root" "/b" "$(canon '/a/../b')"
is "canonical: a leading .. of a relative path stays" "../a/b" "$(canon '../a/b')"
is "canonical: a trailing slash is dropped" "a/b" "$(canon 'a/b/')"
is "canonical: a space in a segment survives" "dir with space/S p.scala" "$(canon 'dir with space/S p.scala')"
is "canonical: the root itself" "/" "$(canon '/')"
is "canonical: ~ expands to HOME" "$HOME/x" "$(canon '~/x')"
is "canonical: ~ alone is HOME" "$HOME" "$(canon '~')"
is "canonical: ~ expands against the HOME of the calling shell" "/tmp/dsh-home/x" \
  "$(/bin/sh -c 'HOME=/tmp/dsh-home; . "$1/lib.sh"; dsh_canonical_path "~//x/./y/.."' _ "$engine")"
is "canonical: an unknown ~user is left alone (and then stands down)" '~user/x' "$(canon '~user/x')"
# LEXICAL means the filesystem is not consulted, and that has to be measured in a directory where a
# glob WOULD match: the split inside dsh_canonical_path is unquoted (IFS is `/`, so a segment may
# contain a space), and an unquoted expansion is otherwise PATHNAME-expanded against the caller's cwd
# -- measured before this was fixed, in a cwd holding `backend core out`, `core/*/A.scala` came back as
# `core/backend/core/A.scala`. Globbing is now off around the split, and restored afterwards.
globdir=$(mktemp -d)
mkdir -p "$globdir/backend" "$globdir/core" "$globdir/out" "$globdir/dir with space"
: > "$globdir/a*b.scala"
is "canonical: a glob segment is not expanded (purely lexical)" "core/*/A.scala" \
  "$(cd "$globdir" && canon 'core/*/A.scala')"
is "canonical: a literal * in a filename survives untouched" "a*b.scala" \
  "$(cd "$globdir" && canon 'a*b.scala')"
is "canonical: ? and [ are left as written too" "x?/[a]/A.scala" \
  "$(cd "$globdir" && canon 'x?/[a]/A.scala')"
is "canonical: a segment with a space still survives the same split" "dir with space/A.scala" \
  "$(cd "$globdir" && canon 'dir with space/A.scala')"
is "canonical: a caller whose globbing is already off keeps it off" "yes" \
  "$(/bin/sh -c 'set -f; . "$1/lib.sh"; dsh_canonical_path "x/*/y" >/dev/null; case $- in *f*) echo yes ;; *) echo no ;; esac' _ "$engine")"
is "canonical: a caller whose globbing is on gets it back" "no" \
  "$(/bin/sh -c 'set +f; . "$1/lib.sh"; dsh_canonical_path "x/*/y" >/dev/null; case $- in *f*) echo yes ;; *) echo no ;; esac' _ "$engine")"
rm -rf "$globdir"
# And the guard's own composition of the two steps, through a child shell: a covered path is found
# through a non-canonical spelling, and one that is not a path of the root is not found at all.
relpath() { # relpath <root> <named path>
  /bin/sh -c '
    . "$1/lib.sh"
    root=$2; root_phys=$(CDPATH= cd -- "$root" && pwd -P)
    _rr=$(dsh_canonical_path "$3")
    case "$_rr" in
      "$root"/*) _rr=${_rr#"$root"/} ;;
      "$root_phys"/*) _rr=${_rr#"$root_phys"/} ;;
      /*) _rr="" ;;
      ..|../*) _rr="" ;;
      .) _rr="" ;;
    esac
    printf "%s" "$_rr"' _ "$engine" "$1" "$2"
}
is "coverage: a non-canonical spelling resolves to the indexed path" "core/src/A.scala" \
  "$(relpath "$covroot" "$covroot/./core//src/../src/A.scala")"
is "coverage: a relative non-canonical spelling resolves too" "core/src/A.scala" \
  "$(relpath "$covroot" 'core/./src/A.scala')"
is "coverage: the physical spelling of the root resolves" "core/src/A.scala" \
  "$(relpath "$covroot" "$(CDPATH= cd -- "$covroot" && pwd -P)/core/src/A.scala")"
is "coverage: a path outside the root resolves to nothing" "" \
  "$(relpath "$covroot" '/etc/A.scala')"
is "coverage: a relative path walking out of the root resolves to nothing" "" \
  "$(relpath "$covroot" '../A.scala')"

# An empty tree: the guard asks this question in every session, including one that has not compiled.
covempty=$(mktemp -d)
dsh_coverage_scan "$covempty" "$covempty/index-coverage"
is "coverage: an empty checkout reports 0 of 0, not a division error" \
  "index covers 0 of 0 Scala sources (0%)" "$(dsh_coverage_sentence "$covempty" "$covempty/index-coverage")"
is "coverage: the empty cache is still a valid, empty answer" \
  "$(dsh_coverage_cache_valid "$covempty/index-coverage" && echo ok)" "ok"
is "coverage: the empty cache declares no fingerprint" "none" \
  "$(dsh_coverage_header_field "$covempty/index-coverage" index)"
# The helper is usable from a caller that must not write inside the repository, which is why the
# cache path is the caller's: check-harness.sh points it at its own scratch directory.
dsh_coverage_scan "$covempty" "$covempty/nested/deeper/cache"
is "coverage: the cache path is the caller's, directories included" \
  "$(dsh_coverage_cache_valid "$covempty/nested/deeper/cache" && echo ok)" "ok"
# The same helpers through a child shell that sources lib.sh, which is how check-harness.sh uses them.
is "coverage: the helpers work through a child shell with lib.sh sourced" "2" \
  "$(coverage_count_child "$covcache")"
rm -rf "$covroot" "$covempty"

# --- (j) the frozen-path helpers ----------------------------------------------------------------
# Every hook that refuses a write to the human's in-flight work asks these two helpers --
# semantic-guard on three routes (the write/edit tools, a bash write destination, the MCP annotated
# buffer) and tool-policy for `rm`/`mv` -- so what a freeze MEANS is pinned here once instead of
# inferred from four call sites. The roots are synthetic and hermetic: a list, a few paths, no
# repository and no Mill. What each block protects:
#   * the PARSE: `<kind>` TAB `<path>` TAB `<reason>`, one line per valid entry, the three shapes
#     (`path`, `dir/`, `prefix/**`) mapping to exact/prefix, blanks and `#` lines ignored, and the
#     path/reason separator a TAB or TWO OR MORE SPACES -- never a single space, which is what lets
#     a path containing a space be carried whole instead of silently mis-frozen;
#   * the REASON is required: an entry without one (or with a single-space separator) is malformed,
#     reported, and never silently enforced or silently dropped -- and it does not stop the
#     well-formed entries from working;
#   * the UNION of the committed file and the machine-local one, committed first (its reason is the
#     one quoted) and byte-identical rows collapsed;
#   * an ABSENT file is no freeze at all, and the parse still succeeds (exit 0, no output);
#   * a MALFORMED entry -- no reason, a single-space separator, an absolute path outside the
#     repository, a relative path walking out, a glob that is not a `/**` suffix -- is reported on
#     stderr and makes the parse exit 1, which is the status `.dsh/engine/check-harness.sh` fails on.
fzlist() { /bin/sh -c '. "$1/lib.sh"; dsh_frozen_paths "$2"' _ "$engine" "$1"; }
fzrc() { /bin/sh -c '. "$1/lib.sh"; dsh_frozen_paths "$2" >/dev/null 2>&1; printf "%s" "$?"' _ "$engine" "$1"; }
fzerr() { /bin/sh -c '. "$1/lib.sh"; dsh_frozen_paths "$2" 2>&1 >/dev/null' _ "$engine" "$1"; }
fzreason() { # fzreason <root> <path> -> the reason, or NO when the path is not frozen
  /bin/sh -c '. "$1/lib.sh"
r=$(dsh_frozen_reason "$3" "$2") && printf "%s" "$r" || printf NO' _ "$engine" "$1" "$2"
}
fzsealed() { # fzsealed <root> <path> -> the reason when SEALED, or NO
  /bin/sh -c '. "$1/lib.sh"
r=$(dsh_sealed_reason "$3" "$2") && printf "%s" "$r" || printf NO' _ "$engine" "$1" "$2"
}
fzaccess() { # fzaccess <root> <path> -> frozen | sealed | NO
  /bin/sh -c '. "$1/lib.sh"
r=$(dsh_frozen_access "$3" "$2") && printf "%s" "$r" || printf NO' _ "$engine" "$1" "$2"
}

fzroot=$(mktemp -d)
mkdir -p "$fzroot/.dsh/.state" "$fzroot/engine/details/src"
{
  printf '# a comment, ignored\n'
  printf '\n'
  printf 'engine/details/src/Foo.scala%san exact path, separated by a TAB\n' "$tab"
  printf 'wiring/details/  the directory shape\n'
  printf 'engine/shape/**  the prefix shape\n'
  printf 'engine/spaced/A B.scala  the spaced path\n'
} > "$fzroot/.dsh/frozen-paths"
is "frozen: the parse names the access, the kind and the reason of every shape" \
  "frozen${tab}exact${tab}engine/details/src/Foo.scala${tab}an exact path, separated by a TAB
frozen${tab}prefix${tab}wiring/details${tab}the directory shape
frozen${tab}prefix${tab}engine/shape${tab}the prefix shape
frozen${tab}exact${tab}engine/spaced/A B.scala${tab}the spaced path" \
  "$(fzlist "$fzroot")"
is "frozen: a well-formed list parses with exit 0" "0" "$(fzrc "$fzroot")"
is "frozen: an exact entry freezes that path" "an exact path, separated by a TAB" \
   "$(fzreason "$fzroot" engine/details/src/Foo.scala)"
is "frozen: an exact entry does not freeze a sibling" "NO" \
   "$(fzreason "$fzroot" engine/details/src/Bar.scala)"
is "frozen: a dir/ entry covers a file deeper in the tree" "the directory shape" \
   "$(fzreason "$fzroot" wiring/details/src/deep/A.scala)"
is "frozen: it covers the directory itself too" "the directory shape" "$(fzreason "$fzroot" wiring/details)"
is "frozen: a prefix/** entry covers a file deeper in the tree" "the prefix shape" \
   "$(fzreason "$fzroot" engine/shape/src/com/A.scala)"
is "frozen: a prefix does not cover a name that merely starts with it" "NO" \
   "$(fzreason "$fzroot" engine/shape-notes/A.md)"
is "frozen: an absolute spelling under the root is the same path" "the prefix shape" \
   "$(fzreason "$fzroot" "$fzroot/engine/./shape//src/A.scala")"
is "frozen: a path outside the repository is never frozen" "NO" "$(fzreason "$fzroot" /etc/passwd)"
is "frozen: a relative path walking out of the repository is never frozen" "NO" \
   "$(fzreason "$fzroot" ../outside/A.scala)"
# A PATH WITH A SPACE. The separator is a TAB or two or more spaces, which is what makes it
# unambiguous: the whole `engine/spaced/A B.scala` is the path, and the truncated spelling a
# single-space parse would produce (`engine/spaced/A`, silently freezing the wrong thing) is NOT
# frozen. Before this rule the spaced entry was mis-read and answered both ways wrongly.
is "frozen: a path with a space is carried whole (the wider separator)" "the spaced path" \
   "$(fzreason "$fzroot" "engine/spaced/A B.scala")"
is "frozen: a spaced path does not freeze its truncated spelling" "NO" \
   "$(fzreason "$fzroot" engine/spaced/A)"

# The union: the committed list first (its reason is the one quoted for a path both files name),
# the machine-local one after it, byte-identical rows collapsed.
union_root=$(mktemp -d)
mkdir -p "$union_root/.dsh/.state"
printf 'engine/shape/**  the committed reason\n' > "$union_root/.dsh/frozen-paths"
printf 'wiring/details/**  machine-local only\n' > "$union_root/.dsh/.state/frozen-paths"
is "frozen: the two files are unioned (committed entry answers)" "the committed reason" \
   "$(fzreason "$union_root" engine/shape/A.scala)"
is "frozen: the two files are unioned (machine-local entry answers)" "machine-local only" \
   "$(fzreason "$union_root" wiring/details/A.scala)"
is "frozen: the parse lists both files' entries" "2" "$(fzlist "$union_root" | wc -l | tr -d ' ')"
printf 'engine/shape/**  a later, different reason for the same path\n' >> "$union_root/.dsh/.state/frozen-paths"
is "frozen: the committed entry's reason is quoted when both name the path" "the committed reason" \
   "$(fzreason "$union_root" engine/shape/A.scala)"
printf 'wiring/details/**  machine-local only\n' >> "$union_root/.dsh/.state/frozen-paths"
is "frozen: a byte-identical row is collapsed in the union" "3" \
   "$(fzlist "$union_root" | wc -l | tr -d ' ')"

# An ABSENT list is no freeze at all -- and not an error: every session before the first freeze
# asks this question, and the answer has to be "nothing is frozen", not a failure.
fzempty=$(mktemp -d)
mkdir -p "$fzempty/.dsh/.state"
is "frozen: an absent list answers 'not frozen'" "NO" "$(fzreason "$fzempty" engine/details/src/Foo.scala)"
is "frozen: an absent list parses to nothing" "" "$(fzlist "$fzempty")"
is "frozen: an absent list is not an error" "0" "$(fzrc "$fzempty")"
printf '# nothing is frozen right now\n' > "$fzempty/.dsh/frozen-paths"
is "frozen: a comments-only list freezes nothing" "NO" "$(fzreason "$fzempty" engine/details/src/Foo.scala)"
# An absolute entry INSIDE the repository is a legitimate spelling of a repo-relative freeze (the
# root prefix is stripped in either spelling), which is what makes a path copied out of a payload
# usable in the list.
printf '%s/engine/abs/**  an absolute spelling inside the repository\n' "$fzempty" > "$fzempty/.dsh/frozen-paths"
is "frozen: an absolute entry inside the repository is accepted" "an absolute spelling inside the repository" \
   "$(fzreason "$fzempty" engine/abs/src/A.scala)"

# A MALFORMED entry is a loud failure (check-harness fails on the exit status), never a silent skip:
# the well-formed entries still decide, and the report names each defect. The first two lines are
# the same defect seen twice -- no separator at all, and a separator that is only one space: both
# are rejected, because neither can tell a path from a reason unambiguously, and the alternative
# (parsing `dir with space/A.scala  reason` as path `dir`) is a freeze of the wrong thing.
fzbad=$(mktemp -d)
mkdir -p "$fzbad/.dsh/.state"
{
  printf 'engine/details/**\n'
  printf 'engine/details/** a single space\n'
  printf '/etc/outside/x  an absolute path outside the repository\n'
  printf '../up/x  walks out of the repository\n'
  printf 'engine/*/A.scala  a glob, not one of the three shapes\n'
  printf 'engine/kept/**  this one is well formed\n'
} > "$fzbad/.dsh/frozen-paths"
is "frozen: a malformed entry fails the parse" "1" "$(fzrc "$fzbad")"
is "frozen: a malformed entry does not stop the well-formed ones" "this one is well formed" \
   "$(fzreason "$fzbad" engine/kept/A.scala)"
is "frozen: an entry with no reason freezes nothing" "NO" "$(fzreason "$fzbad" engine/details/A.scala)"
is "frozen: a single-space separator freezes nothing" "NO" "$(fzreason "$fzbad" engine/details/A)"
fzbad_err=$(fzerr "$fzbad")
has "frozen: the report names the separator rule" "two or more spaces" "$fzbad_err"
has "frozen: the report names the absolute path outside the repository" \
    "absolute path outside the repository" "$fzbad_err"
has "frozen: the report names the path walking out of the repository" \
    "resolves outside the repository" "$fzbad_err"
has "frozen: the report names the glob" "a glob pattern" "$fzbad_err"
rm -rf "$fzroot" "$union_root" "$fzempty" "$fzbad"

# --- sealed access: an optional leading token, `sealed` denies reads too -----------------------
szroot=$(mktemp -d)
mkdir -p "$szroot/.dsh/.state" "$szroot/holdout/test/src" "$szroot/engine/test/src"
{
  printf 'sealed%sholdout/**%sholdout suite: run by the gate at turn-end, never read or edited by the agent\n' "$tab" "$tab"
  printf 'engine/test/**  tests are the human'"'"'s spec; ask in chat to unfreeze a file\n'
  printf 'sealed  .dsh/.state/holdout.log  full holdout output is the human'"'"'s; the agent gets names only\n'
} > "$szroot/.dsh/frozen-paths"
is "sealed: the parse carries the access token" \
  "sealed${tab}prefix${tab}holdout${tab}holdout suite: run by the gate at turn-end, never read or edited by the agent
frozen${tab}prefix${tab}engine/test${tab}tests are the human's spec; ask in chat to unfreeze a file
sealed${tab}exact${tab}.dsh/.state/holdout.log${tab}full holdout output is the human's; the agent gets names only" \
  "$(fzlist "$szroot")"
is "sealed: a sealed path is frozen for writes" \
  "holdout suite: run by the gate at turn-end, never read or edited by the agent" "$(fzreason "$szroot" holdout/test/src/X.scala)"
is "sealed: a sealed path is sealed for reads" \
  "holdout suite: run by the gate at turn-end, never read or edited by the agent" "$(fzsealed "$szroot" holdout/test/src/X.scala)"
is "sealed: a merely frozen path is NOT sealed for reads" NO "$(fzsealed "$szroot" engine/test/src/A.scala)"
is "sealed: access of a frozen path" frozen "$(fzaccess "$szroot" engine/test/src/A.scala)"
is "sealed: access of a sealed path" sealed "$(fzaccess "$szroot" holdout/x)"
is "sealed: access of an unfrozen path" NO "$(fzaccess "$szroot" core/src/A.scala)"
is "sealed: the sealed exact log file" sealed "$(fzaccess "$szroot" .dsh/.state/holdout.log)"

# a bare file name with no second separator is a path, not a token
printf 'README  a bare name is a path\n' >> "$szroot/.dsh/frozen-paths"
is "sealed: a bare file name stays an exact frozen path" frozen "$(fzaccess "$szroot" README)"

# an unknown access token is malformed, loudly
printf 'locked%score/**%snot a word this grammar knows\n' "$tab" "$tab" >> "$szroot/.dsh/frozen-paths"
is "sealed: an unknown access token makes the parse exit 1" 1 "$(fzrc "$szroot")"
case "$(fzerr "$szroot")" in
  *"unknown access token"*) is "sealed: the unknown token is reported by name" yes yes ;;
  *) is "sealed: the unknown token is reported by name" yes "no: $(fzerr "$szroot")" ;;
esac
# it does not silence the well-formed entries
is "sealed: well-formed entries still bind beside a malformed one" sealed "$(fzaccess "$szroot" holdout/x)"

# the union takes the STRICTER access, whichever file says it
uzroot=$(mktemp -d)
mkdir -p "$uzroot/.dsh/.state"
printf 'engine/test/**  committed freeze\n' > "$uzroot/.dsh/frozen-paths"
printf 'sealed  engine/test/**  machine-local seal\n' > "$uzroot/.dsh/.state/frozen-paths"
is "sealed: a machine-local seal tightens a committed freeze" sealed "$(fzaccess "$uzroot" engine/test/src/A.scala)"
printf 'sealed  engine/test/**  committed seal\n' > "$uzroot/.dsh/frozen-paths"
printf 'engine/test/**  machine-local freeze\n' > "$uzroot/.dsh/.state/frozen-paths"
is "sealed: a machine-local freeze cannot weaken a committed seal" sealed "$(fzaccess "$uzroot" engine/test/src/A.scala)"
rm -rf "$szroot" "$uzroot"

# A bare, dot-less, slash-less exact path (LICENSE, Makefile, ...) is NOT an unknown token just
# because its REASON happens to contain a run of two-or-more spaces: the token/path call looks at
# the remainder's own first field, and a reason's first sentence ("Ask first.") has a space in it,
# so it is not path-shaped and LICENSE stays a frozen exact path.
bwroot=$(mktemp -d)
mkdir -p "$bwroot/.dsh/.state"
printf 'LICENSE%sAsk first.  Do not edit.\n' "$tab" > "$bwroot/.dsh/frozen-paths"
is "sealed: a bare exact path is not an unknown token when its reason has a wide gap" \
  frozen "$(fzaccess "$bwroot" LICENSE)"
is "sealed: that entry still parses with exit 0" 0 "$(fzrc "$bwroot")"
rm -rf "$bwroot"

# A bare word followed by what LOOKS like a path (has a `/` or a `.`, no space in it) IS an unknown
# token, whichever separator introduced it.
utroot=$(mktemp -d)
mkdir -p "$utroot/.dsh/.state"
printf 'locked%score/**%sreason\n' "$tab" "$tab" > "$utroot/.dsh/frozen-paths"
is "sealed: a bare word before a prefix path is an unknown token" 1 "$(fzrc "$utroot")"
has "sealed: the prefix-path case names the unknown token" "unknown access token" "$(fzerr "$utroot")"
printf 'locked%sREADME.md%sreason\n' "$tab" "$tab" > "$utroot/.dsh/frozen-paths"
is "sealed: a bare word before a dotted filename is an unknown token" 1 "$(fzrc "$utroot")"
has "sealed: the dotted-filename case names the unknown token" "unknown access token" "$(fzerr "$utroot")"
rm -rf "$utroot"

# --- (k) payload_has: is a field THERE, not just non-empty? -------------------------------------
# The annotated-buffer route needs the distinction: `annotated_source(uri, write="")` carries a
# `write` argument (a truncation, which the frozen-path rule must decide) while
# `annotated_source(uri)` carries none (a read, which must stay allowed), and `payload_get` renders
# both as the empty string. Asserted through BOTH readers, like every other payload question.
GATE_PAYLOAD='{"write":"","uri":"u","nil":null,"o":{"x":1},"f":false}'
export GATE_PAYLOAD
has_field() { # has_field <dotted path> <want>
  if [ "$have_jq" = 1 ]; then
    is "jq      payload_has $1" "$2" \
       "$(PATH="$jq_only" /bin/sh -c '. "$1/lib.sh"; if payload_has "$2"; then printf yes; else printf no; fi' _ "$engine" "$1")"
  fi
  if [ "$have_py" = 1 ]; then
    is "python3 payload_has $1" "$2" \
       "$(PATH="$python_only" /bin/sh -c '. "$1/lib.sh"; if payload_has "$2"; then printf yes; else printf no; fi' _ "$engine" "$1")"
  fi
  return 0
}
has_field write yes
has_field uri yes
has_field absent no
has_field nil no
has_field o yes
has_field o.x yes
has_field o.y no
has_field f yes

rm -rf "$jq_only" "$python_only" "$no_reader"

# --- (l) dsh_contract_get: read one key from .dsh/contract ------
ctget() { /bin/sh -c '. "$1/lib.sh"
v=$(dsh_contract_get "$3" "$2") && printf "%s" "$v" || printf NO' _ "$engine" "$1" "$2"; }
ctroot=$(mktemp -d); mkdir -p "$ctroot/.dsh"
printf '# The gate interface\npreCommit  = ./mill -j 1 preCommit\nholdout = ./mill -j 1 --ticker false holdout.test\n\nroots = .\n' > "$ctroot/.dsh/contract"
is "contract: a key with padded = is read" "./mill -j 1 preCommit" "$(ctget "$ctroot" preCommit)"
is "contract: a key with tight = is read" "./mill -j 1 --ticker false holdout.test" "$(ctget "$ctroot" holdout)"
is "contract: an absent key is NO" NO "$(ctget "$ctroot" prePush)"
rm -f "$ctroot/.dsh/contract"
is "contract: a missing file is NO" NO "$(ctget "$ctroot" holdout)"
rm -rf "$ctroot"

# --- (l2) dsh_contract_for_module: the contract value with <module> substituted ------
cfm() { /bin/sh -c '. "$1/lib.sh"; dsh_contract_for_module "$3" "$4" "$2"' _ "$engine" "$1" "$2" "$3"; }
cfroot=$(mktemp -d); mkdir -p "$cfroot/.dsh"
printf 'fastTests = ./mill -j 1 --ticker false <module>.test.testOnly -- %s\n' "'*Props'" > "$cfroot/.dsh/contract"
is "contract-for-module: substitution" "./mill -j 1 --ticker false engine.shape.test.testOnly -- '*Props'" "$(cfm "$cfroot" fastTests engine.shape)"
is "contract-for-module: absent key" "" "$(cfm "$cfroot" turnEndTests engine.shape)"
rm -rf "$cfroot"

wf() { /bin/sh -c '. "$1/lib.sh"; dsh_weaver_failures' _ "$engine"; }
weaver_out='com.github.mercurievv.skreeep2.holdout.PlaybackHoldout
  + gain then seek keeps position 12ms
  - stop releases device 4ms
  - a second failure 9ms
  + a third one 1ms

*************FAILURES**************
com.github.mercurievv.skreeep2.holdout.PlaybackHoldout
  - stop releases device 4ms
  Expected true but got false (PlaybackHoldout.scala:41)
  - a second failure 9ms
  Expected 3 but got 4 (PlaybackHoldout.scala:58)

Total 4, Failed 2, Passed 2, Ignored 0, Cancelled 0'
is "weaver: names only, counts from the Total line" \
  "holdout: 2 passed, 2 failed
  - PlaybackHoldout.stop releases device
  - PlaybackHoldout.a second failure" \
  "$(printf '%s\n' "$weaver_out" | wf)"
is "weaver: no assertion text leaks" "" "$(printf '%s\n' "$weaver_out" | wf | grep -c 'Expected' | sed 's/^0$//')"
is "weaver: all green" "holdout: 3 passed, 0 failed" \
  "$(printf 'x.Y\n  + a 1ms\n  + b 1ms\n  + c 1ms\n\nTotal 3, Failed 0, Passed 3, Ignored 0, Cancelled 0\n' | wf)"
is "weaver: a mill-prefixed line still parses" "holdout: 0 passed, 1 failed
  - Y.a" \
  "$(printf '[12/40] holdout.test x.Y\n[12/40]   - a 1ms\n[12/40] Total 1, Failed 1, Passed 0, Ignored 0, Cancelled 0\n' | wf)"
is "weaver: total present but no failing lines parse" "holdout: 2 failed, names unavailable" \
  "$(printf 'garbage\nTotal 5, Failed 2, Passed 3, Ignored 0, Cancelled 0\n' | wf)"
is "weaver: no total line at all" "holdout: result unreadable" "$(printf 'compilation failed\n' | wf)"
is "weaver: a bare mill task path is not mistaken for a suite header" "holdout: 0 passed, 1 failed
  - Y.a" \
  "$(printf '[12/40] holdout.test.testForked\nx.Y\n  - a 1ms\nTotal 1, Failed 1, Passed 0, Ignored 0, Cancelled 0\n' | wf)"

# Real `./mill -j 1 --ticker false holdout.test` output has no indentation, no Total line, and wraps
# the header/marker/duration in ANSI SGR escapes -- captured verbatim from a real run (see the task-4
# report for the `cat -v` transcripts this is transcribed from).
is "weaver: a real all-green weaver run (ANSI, no Total line, no indentation)" \
  "holdout: 1 passed, 0 failed" \
  "$(printf 'Running Test Class com.github.mercurievv.skreeep2.holdout.SmokeHoldout\n\033[36mcom.github.mercurievv.skreeep2.holdout.SmokeHoldout\033[0m\n\033[32m+ \033[0mthe holdout suite runs under the gate \033[37m\033[1m7ms\033[0m\n' | wf)"
is "weaver: a real failing weaver run (ANSI, FAILURES banner, no Total line)" \
  "holdout: 1 passed, 1 failed
  - SmokeHoldout.deliberately failing" \
  "$(printf 'Running Test Class com.github.mercurievv.skreeep2.holdout.SmokeHoldout\n\033[36mcom.github.mercurievv.skreeep2.holdout.SmokeHoldout\033[0m\n\033[32m+ \033[0mthe holdout suite runs under the gate \033[37m\033[1m10ms\033[0m\n\033[31m- \033[0mdeliberately failing \033[37m\033[1m22ms\033[0m\n\033[31m*************\033[0mFAILURES\033[31m**************\033[0m\n\033[36mcom.github.mercurievv.skreeep2.holdout.SmokeHoldout\033[0m\n\033[31m- \033[0mdeliberately failing \033[37m\033[1m22ms\033[0m\n\033[31m  assertion failed (../../../holdout/test/src/com/github/mercurievv/skreeep2/holdout/SmokeHoldout.scala:12)\n\033[31m\n\033[31m  1 == 2\033[0m\n' | wf)"
is "weaver: pre-suite +/- noise before any header is never counted" \
  "holdout: 1 passed, 0 failed" \
  "$(printf -- '- a compiler note that looks like a marker 1ms\n+ another stray line\nRunning Test Class x.Y\n+ real pass 3ms\n' | wf)"

hc() { /bin/sh -c '. "$1/lib.sh"; dsh_holdout_checks "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
hcroot=$(mktemp -d); mkdir -p "$hcroot/.dsh/.state" "$hcroot/.dsh/engine/hooks"
printf 'engine\tengine\tfmt,scalafix,tests\nwiring\twiring\tfmt,tests\nholdout\tholdout\t\n' > "$hcroot/.dsh/.state/modules.tsv"
printf 'holdout = ./mill -j 1 --ticker false holdout.test\n' > "$hcroot/.dsh/contract"
{
  printf 'sealed\tholdout/**\tholdout suite\n'
  printf 'engine/test/**\ttests are the human'"'"'s spec\n'
  printf 'wiring/test/**\ttests are the human'"'"'s spec\n'
  for p in .dsh/frozen-paths .dsh/contract .dsh/hooks.json .dsh/engine/gate.sh .dsh/engine/lib.sh '.dsh/engine/hooks/**' .dsh/engine/check-harness.sh \
           .ignore .claude/settings.json .claude/settings.local.json .dsh/cc-settings.json \
           .dsh/.state/receipts .dsh/.state/modules.tsv; do
    printf '%s\tthe harness is the human'"'"'s\n' "$p"
  done
} > "$hcroot/.dsh/frozen-paths"
out=$(hc "$hcroot")
# The self-freeze set is thirteen paths, and the ok row names every one of them.
for p in frozen-paths contract hooks.json gate.sh lib.sh 'hooks/**' check-harness.sh .ignore .claude/settings.json .claude/settings.local.json cc-settings.json .state/receipts .state/modules.tsv; do
  case "$out" in *"ok"*"self-freeze is complete ("*"$p"*) is "holdout-checks: rule 3's ok row names $p" ok ok ;; *) is "holdout-checks: rule 3's ok row names $p" ok "$out" ;; esac
done
case "$out" in *FAIL*) is "holdout-checks: a complete installation has no FAIL" none "$out" ;; *) is "holdout-checks: a complete installation has no FAIL" ok ok ;; esac
case "$out" in *"rc=0"*) is "holdout-checks: exit 0 when complete" ok ok ;; *) is "holdout-checks: exit 0 when complete" ok "$out" ;; esac

# rule 1: a tests module without a freeze
printf 'score\tscore\tfmt,tests\n' >> "$hcroot/.dsh/.state/modules.tsv"
case "$(hc "$hcroot")" in *"FAIL"*"score"*) is "holdout-checks: rule 1 names the unfrozen test module" ok ok ;; *) is "holdout-checks: rule 1 names the unfrozen test module" ok "$(hc "$hcroot")" ;; esac
sed -i.bak '/^score/d' "$hcroot/.dsh/.state/modules.tsv"

# rule 2: holdout merely frozen, not sealed
sed -i.bak 's/^sealed\tholdout/holdout/' "$hcroot/.dsh/frozen-paths"
case "$(hc "$hcroot")" in *"FAIL"*"sealed"*) is "holdout-checks: rule 2 requires a seal on the holdout target" ok ok ;; *) is "holdout-checks: rule 2 requires a seal on the holdout target" ok "$(hc "$hcroot")" ;; esac
sed -i.bak 's/^holdout\/\*\*/sealed\tholdout\/**/' "$hcroot/.dsh/frozen-paths"

# rule 3: a self-freeze missing -- one of the original seven, and one of each later-added group
# (the ripgrep ignore file, the live Claude Code wiring, the gate's own state files).
for p in .dsh/engine/gate.sh .ignore .claude/settings.local.json .dsh/.state/receipts .dsh/.state/modules.tsv; do
  esc=$(printf '%s' "$p" | sed 's/[.\/*]/\\&/g')
  sed -i.bak "/^$esc\t/d" "$hcroot/.dsh/frozen-paths"
  case "$(hc "$hcroot")" in *"FAIL"*"$p"*) is "holdout-checks: rule 3 names the missing self-freeze $p" ok ok ;; *) is "holdout-checks: rule 3 names the missing self-freeze $p" ok "$(hc "$hcroot")" ;; esac
  printf '%s\tthe harness\n' "$p" >> "$hcroot/.dsh/frozen-paths"
done
is "holdout-checks: rule 3 is satisfied again once the entry is back" 0 "$(hc "$hcroot" | grep -c '^FAIL')"

# rule 4: malformed entry
printf 'locked\tcore/**\tnope\n' >> "$hcroot/.dsh/frozen-paths"
out4=$(hc "$hcroot")
case "$out4" in *"FAIL"*"malformed"*) is "holdout-checks: rule 4 fails on a malformed entry" ok ok ;; *) is "holdout-checks: rule 4 fails on a malformed entry" ok "$out4" ;; esac
is "holdout-checks: rule 4's row is exactly one physical line" 1 "$(printf '%s\n' "$out4" | grep -c '^FAIL')"
is "holdout-checks: no line lacks a leading ok|FAIL|note|rc= tag" 0 "$(printf '%s\n' "$out4" | grep -Evc '^(ok|FAIL|note|rc=)')"
sed -i.bak '/^locked/d' "$hcroot/.dsh/frozen-paths"

# rule 5: no holdout line -> note, not FAIL
: > "$hcroot/.dsh/contract"
out=$(hc "$hcroot")
case "$out" in *"note"*"holdout"*) is "holdout-checks: rule 5 notes an absent holdout line" ok ok ;; *) is "holdout-checks: rule 5 notes an absent holdout line" ok "$out" ;; esac
case "$out" in *"rc=0"*) is "holdout-checks: rule 5 does not fail" ok ok ;; *) is "holdout-checks: rule 5 does not fail" ok "$out" ;; esac
printf 'holdout = ./mill -j 1 --ticker false holdout.test\n' > "$hcroot/.dsh/contract"

# rule 6: holdout reachable from preCommit
sed -i.bak 's/^holdout\tholdout\t$/holdout\tholdout\tfmt,tests/' "$hcroot/.dsh/.state/modules.tsv"
case "$(hc "$hcroot")" in *"FAIL"*"preCommit"*) is "holdout-checks: rule 6 fails when holdout is in preCommit's aggregates" ok ok ;; *) is "holdout-checks: rule 6 fails when holdout is in preCommit's aggregates" ok "$(hc "$hcroot")" ;; esac
sed -i.bak 's/^holdout\tholdout\tfmt,tests$/holdout\tholdout\t/' "$hcroot/.dsh/.state/modules.tsv"

# four-column map (spec 2026-10-01 §2): field 4 (dependents) must never leak into the capabilities
hc3_out=$(hc "$hcroot")
printf 'engine\tengine\tfmt,scalafix,tests\twiring\nwiring\twiring\tfmt,tests\t\nholdout\tholdout\t\t\n' > "$hcroot/.dsh/.state/modules.tsv"
is "holdout checks: a four-column map gives the same verdict as three columns" \
  "$hc3_out" "$(hc "$hcroot")"
# ...and with engine's test root unfrozen, the four-column row must still be seen as tests-capable
sed -i.bak '/^engine\/test/d' "$hcroot/.dsh/frozen-paths"
case "$(hc "$hcroot")" in *"FAIL"*"engine"*) is "holdout checks: a four-column row keeps its tests capability" ok ok ;; *) is "holdout checks: a four-column row keeps its tests capability" ok "$(hc "$hcroot")" ;; esac
printf 'engine/test/**\ttests are the human'"'"'s spec\n' >> "$hcroot/.dsh/frozen-paths"
# ...and an empty-caps row whose dependents field holds `tests`: a whitespace-collapsing `read` would
# shift field 4 into caps and demand a freeze for a compile-only module (x/test is not frozen).
printf 'engine\tengine\tfmt,scalafix,tests\nwiring\twiring\tfmt,tests\nholdout\tholdout\t\nx\tx\t\n' > "$hcroot/.dsh/.state/modules.tsv"
hc3x_out=$(hc "$hcroot")
printf 'engine\tengine\tfmt,scalafix,tests\twiring\nwiring\twiring\tfmt,tests\t\nholdout\tholdout\t\t\nx\tx\t\ttests\n' > "$hcroot/.dsh/.state/modules.tsv"
is "holdout checks: a four-column empty-caps row gives the same verdict as three columns" \
  "$hc3x_out" "$(hc "$hcroot")"
printf 'engine\tengine\tfmt,scalafix,tests\nwiring\twiring\tfmt,tests\nholdout\tholdout\t\n' > "$hcroot/.dsh/.state/modules.tsv"

# rule 1: the final unterminated row must still be checked (no trailing newline drops it via `read`)
noeol=$(mktemp -d); mkdir -p "$noeol/.dsh/.state"
printf 'engine\tengine\tfmt,tests' > "$noeol/.dsh/.state/modules.tsv"
case "$(hc "$noeol")" in *"FAIL"*"engine"*) is "holdout-checks: rule 1 checks the last row even without a trailing newline" ok ok ;; *) is "holdout-checks: rule 1 checks the last row even without a trailing newline" ok "$(hc "$noeol")" ;; esac
rm -rf "$noeol"

# rule 1: no coverage map at all -> note, not ok/FAIL (the map is a cache the build regenerates)
mv "$hcroot/.dsh/.state/modules.tsv" "$hcroot/.dsh/.state/modules.tsv.hidden"
out1=$(hc "$hcroot")
case "$out1" in *"note"*"no coverage map"*) is "holdout-checks: rule 1 notes an absent coverage map" ok ok ;; *) is "holdout-checks: rule 1 notes an absent coverage map" ok "$out1" ;; esac
mv "$hcroot/.dsh/.state/modules.tsv.hidden" "$hcroot/.dsh/.state/modules.tsv"
rm -rf "$hcroot"

# --- dependents column: dsh_dependents_column_check ------------------------------------------------
dcc() { /bin/sh -c '. "$1/lib.sh"; dsh_dependents_column_check "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
dcroot=$(mktemp -d); mkdir -p "$dcroot/.dsh/.state"
is "dependents column: no map → nothing to say" "rc=0" "$(dcc "$dcroot")"
printf 'core\tcore\ttests\napp\tapp\ttests\n' > "$dcroot/.dsh/.state/modules.tsv"
is "dependents column: three-column map → a note naming the fix" \
  "$(printf 'note\tdownstream tests disabled — the module map has no dependents column; update buildKit/Gate.mill (moduleMapRows) and re-run ./mill moduleMap\nrc=0')" \
  "$(dcc "$dcroot")"
printf 'core\tcore\ttests\tapp\napp\tapp\ttests\t\n' > "$dcroot/.dsh/.state/modules.tsv"
is "dependents column: four-column map → ok" \
  "$(printf 'ok\tthe module map lists each module'"'"'s dependents, so turn-end runs their tests\nrc=0')" \
  "$(dcc "$dcroot")"
rm -rf "$dcroot"

# --- feedback: dsh_feedback_parse ------------------------------------------------------------------
fp() { /bin/sh -c '. "$1/lib.sh"; dsh_feedback_parse "${2:-auto}"' _ "$engine" "${1:-}"; }
tr_dir="$engine/tests/transcripts"

# weaver + weaver-scalacheck, real capture (ANSI present in the -color file)
out=$(fp < "$tr_dir/weaver-scalacheck-fail-color.txt")
case "$out" in
  "counts${tab}1${tab}2${tab}"*) is "parse: counts from the real weaver run" ok ok ;;
  *) is "parse: counts from the real weaver run" "counts 1 2 …" "$(printf '%s' "$out" | head -1)" ;;
esac
is "parse: the property failure is a property record" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}property\$")"
is "parse: the plain expect failure is a test record" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}test\$")"
is "parse: the property's name" "name${tab}every list is short (deliberately false)" "$(printf '%s\n' "$out" | grep "^name${tab}every" )"
is "parse: the property's suite" "suite${tab}com.github.mercurievv.skreeep2.backend.cpu.CaptureProps" "$(printf '%s\n' "$out" | grep "^suite" | head -1)"
is "parse: the counterexample is an arg row" 1 "$(printf '%s\n' "$out" | grep -c "^arg${tab}ARG_0${tab}List(")"
is "parse: the arg value ends at the value, not the source location" 1 "$(printf '%s\n' "$out" | grep -c "^arg${tab}ARG_0${tab}List(.*)\$")"
is "parse: weaver-scalacheck does not shrink, so no _ORIGINAL row" 0 "$(printf '%s\n' "$out" | grep -c "_ORIGINAL")"
is "parse: the property's message names the try and the assertion" "message${tab}Property test failed on try 1: assertion failed (../../../backend/cpu/test-draft/src/com/github/mercurievv/skreeep2/backend/cpu/CaptureProps.scala:11)" "$(printf '%s\n' "$out" | grep '^message' | head -1)"
is "parse: the plain expect's message is the assertion line" "message${tab}assertion failed (../../../backend/cpu/test-draft/src/com/github/mercurievv/skreeep2/backend/cpu/CaptureProps.scala:14)" "$(printf '%s\n' "$out" | grep '^message' | sed -n 2p)"
is "parse: no raw line leaks into a message" 0 "$(printf '%s\n' "$out" | grep -c 'Seed.fromBase64')"
is "parse: the start-up NoClassDefFoundError noise before the suite ran is not an infra record" 0 "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra")"
is "parse: no ANSI escape survives" 0 "$(printf '%s\n' "$out" | grep -c "$(printf '\033')")"
is "parse: every record ends in a blank line (two records, two blanks)" 2 "$(fp < "$tr_dir/weaver-scalacheck-fail-color.txt" | grep -c '^$')"
is "parse: the uncoloured capture parses identically apart from durations" "$(printf '%s\n' "$out" | grep -v '^counts' | sed 's/List([^)]*)/List(…)/; s/Seed[^)]*)//')" "$(fp < "$tr_dir/weaver-scalacheck-fail.txt" | grep -v '^counts' | sed 's/List([^)]*)/List(…)/; s/Seed[^)]*)//')"

# green run
is "parse: a green run has no records" "counts${tab}2${tab}0" "$(fp < "$tr_dir/weaver-green.txt" | cut -f1-3 | head -1)"
is "parse: a green run emits no kind row" 0 "$(fp < "$tr_dir/weaver-green.txt" | grep -c '^kind')"

# a weaver listing cut off before its FAILURES block still yields a record per `-` line
cut='Running Test Class com.x.YSpec
+ a 1ms
- b 2ms'
out=$(printf '%s\n' "$cut" | fp weaver)
is "parse(weaver, truncated): counts" "counts${tab}1${tab}1" "$(printf '%s\n' "$out" | cut -f1-3 | head -1)"
is "parse(weaver, truncated): one test record named from the listing" "kind${tab}test
suite${tab}com.x.YSpec
name${tab}b" "$(printf '%s\n' "$out" | grep -E '^(kind|suite|name)')"

# a TAB inside a raw message must never split the record into extra fields
tabmsg=$(printf 'expected\tA but got\tB')
w='Running Test Class com.x.TabSpec
- t 1ms

*************FAILURES**************
- t 1ms
'"$tabmsg"
out=$(printf '%s\n' "$w" | fp weaver)
is "parse: a TAB inside a message is sanitised to a space" "message${tab}expected A but got B" "$(printf '%s\n' "$out" | grep '^message')"

# plain scalacheck (synthetic; the canonical runner shape)
sc='! Prop.reverse.reverse: Falsified after 3 passed tests.
> ARG_0: List("")
> ARG_0_ORIGINAL: List("a", "")
Found 1 failing properties.'
out=$(printf '%s\n' "$sc" | fp scalacheck)
is "parse(scalacheck): kind" "kind${tab}property" "$(printf '%s\n' "$out" | grep '^kind')"
is "parse(scalacheck): name" "name${tab}Prop.reverse.reverse" "$(printf '%s\n' "$out" | grep '^name')"
is "parse(scalacheck): shrunk arg" "arg${tab}ARG_0${tab}List(\"\")" "$(printf '%s\n' "$out" | grep "^arg${tab}ARG_0${tab}")"
is "parse(scalacheck): original arg" "arg${tab}ARG_0_ORIGINAL${tab}List(\"a\", \"\")" "$(printf '%s\n' "$out" | grep "^arg${tab}ARG_0_ORIGINAL")"
is "parse(scalacheck): message" "message${tab}Falsified after 3 passed tests." "$(printf '%s\n' "$out" | grep '^message')"
is "parse(scalacheck): auto-detected" "kind${tab}property" "$(printf '%s\n' "$sc" | fp | grep '^kind')"

# munit (synthetic)
mu='com.example.FooSuite:
  + adds 0.01s
==> X com.example.FooSuite.subtracts  0.02s munit.ComparisonFailException: FooSuite.scala:9
  expected 0 but got 1
Total 2, Failed 1'
out=$(printf '%s\n' "$mu" | fp munit)
is "parse(munit): kind" "kind${tab}test" "$(printf '%s\n' "$out" | grep '^kind')"
is "parse(munit): suite.name" "suite${tab}com.example.FooSuite
name${tab}subtracts" "$(printf '%s\n' "$out" | grep -E '^(suite|name)')"
is "parse(munit): counts from the Total line" "counts${tab}1${tab}1" "$(printf '%s\n' "$out" | cut -f1-3 | head -1)"
is "parse(munit): auto-detected" "kind${tab}test" "$(printf '%s\n' "$mu" | fp | grep '^kind')"

# infra classifier wins over assertion adapters
inf='Running Test Class com.x.Y
Exception in thread "main" java.lang.NoClassDefFoundError: cats/effect/unsafe/UnsafeNonFatal
	at cats.effect.unsafe.WorkerThread.lookForWork$1(WorkerThread.scala:551)
	at cats.effect.unsafe.WorkerThread.run(WorkerThread.scala:942)
Caused by: java.lang.ClassNotFoundException: cats.effect.unsafe.UnsafeNonFatal
- some test 1ms'
out=$(printf '%s\n' "$inf" | fp)
is "parse(infra): one infra record" "1" "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra")"
is "parse(infra): no test record beside it" 0 "$(printf '%s\n' "$out" | grep -c "^kind${tab}test")"
is "parse(infra): the exception line is the message" "message${tab}Exception in thread \"main\" java.lang.NoClassDefFoundError: cats/effect/unsafe/UnsafeNonFatal" "$(printf '%s\n' "$out" | grep '^message')"
is "parse(infra): exactly the three stack rows are details" 3 "$(printf '%s\n' "$out" | grep -c '^detail')"
# a real Mill 1.x / Scala 3 compile failure: the E-line carries file:line:col and is the message; the
# `Compilation failed` line after it is a marker too but does not replace the E-line
cf='[error] -- [E006] Not Found Error: app/test/src/x/PhraseProps.scala:12:5
[error] 12 |    expect(strikes.isEmpty)
[error]    |    ^^^^^^
[error]    |    Not found: expect
[error] app.test.compile Compilation failed
[error] 1 tasks failed
[error] app.test.compile Compilation failed'
out=$(printf '%s\n' "$cf" | fp)
is "parse(infra): a Scala 3 compile failure is infra" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra")"
is "parse(infra): the compile failure is one record, no unreadable" 0 "$(printf '%s\n' "$out" | grep -c "^kind${tab}unreadable")"
case "$(printf '%s\n' "$out" | grep '^message')" in "message${tab}-- [E006] Not Found Error: app/test/src/x/PhraseProps.scala:12:5"*) is "parse(infra): the message is the E-line with file:line:col" ok ok ;; *) is "parse(infra): the message is the E-line with file:line:col" ok "$(printf '%s\n' "$out" | grep '^message')" ;; esac
is "parse(infra): 'Compilation failed' alone is infra" 1 "$(printf '[error] app.test.compile Compilation failed\n' | fp | grep -c "^kind${tab}infra")"
is "parse(infra): lower-case 'compilation failed' is infra" 1 "$(printf 'compilation failed\n' | fp | grep -c "^kind${tab}infra")"
is "parse(infra): 'tasks failed' alone is NOT infra (it follows a red test run too)" 0 "$(printf '[error] 1 tasks failed\n' | fp | grep -c "^kind${tab}infra")"

# infra candidates are cleared by later test markers, not only by a suite header
log='Running Test Class com.x.YSpec
com.x.YSpec
+ a 1ms
Error: connection refused
+ b 1ms'
out=$(printf '%s\n' "$log" | fp)
is "parse(infra): an app log line between passing markers is not infra — counts" "counts${tab}2${tab}0" "$(printf '%s\n' "$out" | cut -f1-3 | head -1)"
is "parse(infra): an app log line between passing markers yields no record" 0 "$(printf '%s\n' "$out" | grep -c '^kind')"
is "parse(infra): 'no tests found' is only infra at line start" 0 "$(printf 'com.x.YSpec\n+ a 1ms\nINFO no tests found in registry\n+ b 1ms\n' | fp | grep -c '^kind')"
is "parse(infra): a bare 'No tests found' with nothing run is infra" 1 "$(printf 'No tests found\n' | fp | grep -c "^kind${tab}infra")"
is "parse(scalacheck): a '!' marker clears a pending infra candidate" "kind${tab}property" "$(printf 'Error: warming up\n! P: Falsified after 1 passed tests.\n' | fp | grep '^kind')"
is "parse(munit): a '==> X' marker clears a pending infra candidate" "kind${tab}test" "$(printf 'Error: warming up\n==> X a.B.c 0.1s boom\n' | fp | grep '^kind')"

# Mill-prefixed scalacheck lines are still auto-detected
scp='[12/34] ! Prop.x: Falsified after 2 passed tests.
[12/34] > ARG_0: 7
[12/34] Found 1 failing properties.'
out=$(printf '%s\n' "$scp" | fp)
is "parse(scalacheck): Mill-prefixed lines auto-detect" "kind${tab}property" "$(printf '%s\n' "$out" | grep '^kind')"
is "parse(scalacheck): Mill-prefixed arg" "arg${tab}ARG_0${tab}7" "$(printf '%s\n' "$out" | grep '^arg')"

# the counterexample is split at the FIRST " and input ", so a string value containing it survives
str='Running Test Class com.x.S
com.x.S
- p 1ms
*************FAILURES**************
com.x.S
- p 1ms
 [0] Property test failed on try 2 with seed Seed.fromBase64("AAAA=") and input "foo and input bar" (modules/scalacheck/src/weaver/scalacheck/Checkers.scala:195)
 [1] assertion failed (S.scala:3)'
is "parse: a string counterexample containing ' and input ' is kept whole" "arg${tab}ARG_0${tab}\"foo and input bar\"" "$(printf '%s\n' "$str" | fp | grep '^arg')"

# fallback
is "parse(unreadable): garbage" "kind${tab}unreadable" "$(printf 'lorem\nipsum\n' | fp | grep '^kind')"
is "parse(unreadable): header still counts raw lines" "counts${tab}0${tab}0${tab}2" "$(printf 'lorem\nipsum\n' | fp | head -1)"


# --- render -----------------------------------------------------------------------------------
rf() { /bin/sh -c '. "$1/lib.sh"; dsh_render_feedback "$2" "$3"' _ "$engine" "$1" "$2"; }
rec="counts${tab}12${tab}2${tab}84
kind${tab}property
suite${tab}com.x.PhraseProps
name${tab}strikes are strictly increasing
arg${tab}ARG_0${tab}List(Strike(0.0), Strike(0.0))
arg${tab}ARG_0_ORIGINAL${tab}List(Strike(0.0), Strike(0.0), Strike(1.0))
message${tab}expected next - at > 0

kind${tab}test
suite${tab}com.x.ArrangementSpec
name${tab}empty arrangement renders silence
message${tab}expected 0 but got 1 (ArrangementSpec.scala:41)
"
want='FEEDBACK: 12 passed, 2 failed (app.test)
PROPERTY: PhraseProps.strikes are strictly increasing
  ARG_0: List(Strike(0.0), Strike(0.0)) (shrunk from List(Strike(0.0), Strike(0.0), Strike(1.0)))
  FAILURE: expected next - at > 0
TEST: ArrangementSpec.empty arrangement renders silence
  FAILURE: expected 0 but got 1 (ArrangementSpec.scala:41)
Raw output suppressed: 84 lines — .dsh/.state/feedback/x.log'
is "render: golden two-failure block" "$want" "$(printf '%s' "$rec" | rf app.test .dsh/.state/feedback/x.log)"
is "render: identical ORIGINAL is not shown" "  ARG_0: 7" "$(printf 'counts\t1\t1\t5\nkind\tproperty\nsuite\tA.B\nname\tn\narg\tARG_0\t7\narg\tARG_0_ORIGINAL\t7\nmessage\tm\n\n' | rf s l | grep ARG_0)"
is "render: green run is one line" "FEEDBACK: 3 passed, 0 failed (core.test)" "$(printf 'counts\t3\t0\t9\n' | rf core.test l)"
is "render: draft prefix" "DRAFT PROPERTY: P.n" "$(printf 'counts\t0\t1\t3\nkind\tproperty\ndraft\t1\nsuite\tx.P\nname\tn\nmessage\tm\n\n' | rf s l | grep '^DRAFT')"
out=$(printf 'counts\t0\t0\t40\nkind\tinfra\nsuite\t-\nname\t-\nmessage\tjava.lang.OutOfMemoryError: Java heap space\ndetail\tat a.b(C.scala:1)\n\n' | rf s .dsh/.state/feedback/y.log)
is "render: infra headline" "INFRA: java.lang.OutOfMemoryError: Java heap space" "$(printf '%s\n' "$out" | grep '^INFRA')"
is "render: infra keeps raw" "Raw output kept: 40 lines — .dsh/.state/feedback/y.log" "$(printf '%s\n' "$out" | tail -1)"
is "render: unreadable keeps raw" 1 "$(printf 'counts\t0\t0\t7\nkind\tunreadable\nsuite\t-\nname\t-\nmessage\trunner output not recognised\n\n' | rf s l | grep -c '^Raw output kept')"

# a record whose message row already carries embedded TABs (should not occur once dsh_feedback_parse
# sanitises, but the renderer must read the whole rest-of-line rather than truncate at the first TAB)
is "render: a multi-field message row is read whole, tabs kept as-is" "  FAILURE: expected${tab}A but got${tab}B" \
  "$(printf 'counts\t0\t1\t1\nkind\ttest\nsuite\ts\nname\tn\nmessage\texpected\tA but got\tB\n\n' | rf s l | grep '^  FAILURE')"

# --- feedback: the scalafix / scalac adapters (spec 2026-09-20 diagnostic→instruction §2) -------
# Transcripts are real Mill 1.1.7 captures (fixStrict / fix --check with purrism 0.9.1; core.compile
# with a not-found, a type mismatch and a wart). The kinds table is read from the [root] argument
# when one is given, else gate_root -- here a scratch root holding a kinds table (`groot`, below), so
# the engine's tests carry no project's table; the root block further down exercises the table
# mechanics against a fixture table regardless.
# The absolute /Users/viktorskalinins/IdeaProjects/skreeep2 root below is deliberate, not a machine
# leak to "fix": the two purrism transcripts were captured on that checkout and print that path in
# every finding, and the assertions are exactly that the parser normalises it away against [root].
fpr() { /bin/sh -c '. "$1/lib.sh"; dsh_feedback_parse "$2" "$3" "$4"' _ "$engine" "$1" "$2" "${3:-}"; }
out=$(fpr auto /Users/viktorskalinins/IdeaProjects/skreeep2 < "$tr_dir/fixstrict-purrism.txt")
is "scalafix: fixStrict is auto-detected and yields one diagnostic" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")"
is "scalafix: the code is the full lint id" "code${tab}PreferEffectIdioms.manual-resource" "$(printf '%s\n' "$out" | grep "^code${tab}")"
is "scalafix: the file is root-relative with line:col" "file${tab}core/src/com/github/mercurievv/skreeep2/DshScratch.scala:8:5" "$(printf '%s\n' "$out" | grep "^file${tab}")"
is "scalafix: source row" "source${tab}scalafix" "$(printf '%s\n' "$out" | grep "^source${tab}")"
is "scalafix: the message is the captured text, one line" 1 "$(printf '%s\n' "$out" | grep -c "^message${tab}this \`finally\` closes a resource and does something else too, so the close cannot be lifted out mechanically\. ")"
is "scalafix: counts carry errors and warnings" "0${tab}1" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
is "scalafix: no infra record for the Mill summary line" 0 "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra\$")"
is "scalafix: no test/property/unreadable record either" 0 "$(printf '%s\n' "$out" | grep -Ec "^kind${tab}(test|property|unreadable)\$")"
is "scalafix: without a root the file stays absolute" "file${tab}/Users/viktorskalinins/IdeaProjects/skreeep2/core/src/com/github/mercurievv/skreeep2/DshScratch.scala:8:5" "$(fpr scalafix "" < "$tr_dir/fixstrict-purrism.txt" | grep "^file${tab}")"
out=$(fpr auto /Users/viktorskalinins/IdeaProjects/skreeep2 < "$tr_dir/fixcheck-purrism.txt")
is "scalafix: fix --check yields the lint and the pending rewrite" 2 "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")"
is "scalafix: native-format lint keeps its code and location" "code${tab}PreferEffectIdioms.manual-resource
file${tab}core/src/com/github/mercurievv/skreeep2/DshScratch.scala:8:5" "$(printf '%s\n' "$out" | grep -E "^(code|file)${tab}" | head -2)"
is "scalafix: pending rewrite code" 1 "$(printf '%s\n' "$out" | grep -c "^code${tab}scalafix.pending-rewrite\$")"
is "scalafix: pending rewrite names the file, root-relative, without a line" "file${tab}core/src/com/github/mercurievv/skreeep2/DshScratch.scala" "$(printf '%s\n' "$out" | grep "^file${tab}" | tail -1)"
is "scalafix: pending rewrite counts as one error, the lint as one warning" "1${tab}1" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
# the captured diff body rewrites `IO.pure` to `IO.delay`; neither hunk line may leak into a record
is "scalafix: diff body lines never become records or messages" 0 "$(printf '%s\n' "$out" | grep -c 'IO\.delay\|^@@\|^+++')"
is "scalafix: source and caret lines never become records" 0 "$(printf '%s\n' "$out" | grep -c 'try IO.pure\|^[[:space:]]*\^$')"
groot=$(mktemp -d "${TMPDIR:-/tmp}/dsh-groot.XXXXXX"); mkdir -p "$groot/.dsh/instructions"
printf '# kind\tregex\nnot-found\t^Not found: \ntype-mismatch\t^Found: \n' > "$groot/.dsh/instructions/scalac-kinds.tsv"
out=$(GATE_ROOT="$groot"; export GATE_ROOT; fpr auto "" < "$tr_dir/scalac-notfound.txt")
is "scalac: auto-detected, one diagnostic" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")"
is "scalac: source row" "source${tab}scalac" "$(printf '%s\n' "$out" | grep "^source${tab}")"
is "scalac: not-found kind" "code${tab}scalac.not-found" "$(printf '%s\n' "$out" | grep "^code${tab}")"
is "scalac: file with line:col" "file${tab}core/src/com/github/mercurievv/skreeep2/DshScratch.scala:4:21" "$(printf '%s\n' "$out" | grep "^file${tab}")"
is "scalac: the headline is the message" "message${tab}Not found: undefinedName" "$(printf '%s\n' "$out" | grep "^message${tab}")"
is "scalac: a one-line headline has no detail rows" 0 "$(printf '%s\n' "$out" | grep -c "^detail${tab}")"
is "scalac: Compilation failed is not infra when a diagnostic was read" 0 "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra\$")"
is "scalac: counts 1 error 0 warnings" "1${tab}0" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
out=$(GATE_ROOT="$groot"; export GATE_ROOT; fpr scalac "" < "$tr_dir/scalac-mismatch.txt")
is "scalac: type-mismatch kind" "code${tab}scalac.type-mismatch" "$(printf '%s\n' "$out" | grep "^code${tab}")"
is "scalac: Found line is the message" "message${tab}Found:    (42 : Int)" "$(printf '%s\n' "$out" | grep "^message${tab}")"
is "scalac: Required line is a detail row" "detail${tab}Required: String" "$(printf '%s\n' "$out" | grep "^detail${tab}")"
out=$(fpr auto "" < "$tr_dir/wart-var.txt")
is "wart: source wart, code wartremover.Var" "source${tab}wart
code${tab}wartremover.Var" "$(printf '%s\n' "$out" | grep -E "^(source|code)${tab}")"
is "wart: message without the bracket" "message${tab}var is disabled" "$(printf '%s\n' "$out" | grep "^message${tab}")"
is "wart: counted as an error" "1${tab}0" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
out=$(printf 'compiling 1 Scala source to out/core/compile.dest/classes ...\ndone compiling\n' | fpr scalac "")
is "scalac: a green compile is counts only" "counts${tab}0${tab}0${tab}2${tab}0${tab}0" "$out"
# a real crash in a compile transcript is still infra: the JVM died, no diagnostic was read
out=$(printf 'compiling 1 Scala source to out/core/compile.dest/classes ...\nException in thread "main" java.lang.OutOfMemoryError: Java heap space\n\tat dotty.tools.dotc.Run.compile(Run.scala:1)\n' | fpr scalac "")
is "scalac: a JVM crash is one infra record with its detail" "kind${tab}infra
message${tab}Exception in thread \"main\" java.lang.OutOfMemoryError: Java heap space
detail${tab}at dotty.tools.dotc.Run.compile(Run.scala:1)" "$(printf '%s\n' "$out" | grep -E "^(kind|message|detail)${tab}")"
is "scalac: the crash header still carries errors and warnings fields" "counts${tab}0${tab}0${tab}3${tab}0${tab}0" "$(printf '%s\n' "$out" | head -1)"
# the kinds table: a fixture root with its own scalac-kinds.tsv classifies the headline; the first
# matching row wins, `#` and blank rows are skipped, and an unmatched headline stays scalac.error
kroot=$(mktemp -d "${TMPDIR:-/tmp}/dsh-kinds.XXXXXX"); mkdir -p "$kroot/.dsh/instructions"
printf '# kind\tregex\n\ntype-mismatch\t^Found: \nnot-found\t^Not found: \n' > "$kroot/.dsh/instructions/scalac-kinds.tsv"
out=$(fpr scalac "$kroot" < "$tr_dir/scalac-notfound.txt")
is "scalac: a kinds table under the [root] argument classifies the headline" "code${tab}scalac.not-found" "$(printf '%s\n' "$out" | grep "^code${tab}")"
out=$(fpr scalac "$kroot" < "$tr_dir/scalac-mismatch.txt")
is "scalac: the table matches the Found/Required pair" "code${tab}scalac.type-mismatch" "$(printf '%s\n' "$out" | grep "^code${tab}")"
out=$(fpr scalac "$kroot" < "$tr_dir/wart-var.txt")
is "scalac: a wart never consults the kinds table" "code${tab}wartremover.Var" "$(printf '%s\n' "$out" | grep "^code${tab}")"
out=$(GATE_ROOT="$kroot" /bin/sh -c '. "$1/lib.sh"; dsh_feedback_parse scalac ""' _ "$engine" < "$tr_dir/scalac-notfound.txt")
is "scalac: without a [root] the kinds table comes from gate_root" "code${tab}scalac.not-found" "$(printf '%s\n' "$out" | grep "^code${tab}")"
rm -r "$kroot" "$groot"
# an unpositioned `-- Error:` headline is its OWN record, every time -- not a fallback for a run with
# no other record: the reviewer's repro (a positioned warning + `-- Error: cyclic reference` + `one
# error found`) used to render as 0 errors, 1 warning while the compile was red
out=$(printf '[warn] a/B.scala:1:2\n  import x.y\n         ^\nunused import\n[error] -- Error: cyclic reference involving object Wiring\n[error] one error found\n[error] one warning found\n[error] core.compile Compilation failed\n' | fpr auto "")
is "scalac: warning block + -- Error headline counts 1 error 1 warning" "1${tab}1" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
is "scalac: … as two diagnostic records, no infra" "2${tab}0" "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")${tab}$(printf '%s\n' "$out" | grep -c "^kind${tab}infra\$")"
is "scalac: the headline record is scalac.error, file -, message the headline" "code${tab}scalac.error
file${tab}-
message${tab}-- Error: cyclic reference involving object Wiring" "$(printf '%s\n' "$out" | grep -E "^(code|file|message)${tab}" | tail -3)"
is "scalac: a [warn] path:l:c block is scalac.warning, counted as a warning" "code${tab}scalac.warning${tab}0${tab}1" "$(printf '[warn] a/B.scala:1:2\n  x\n  ^\nsome unknown warning text\n' | fpr scalac "" | awk -F'\t' '$1=="code"{c=$0} $1=="counts"{e=$5; w=$6} END{print c "\t" e "\t" w}')"
out=$(printf '[error] -- Error: cyclic reference involving object Wiring\n[error] one error found\n[error] core.compile Compilation failed\n' | fpr scalac "")
is "scalac: a lone -- Error headline is one scalac.error record (explicit adapter, as the harness passes it)" "kind${tab}diagnostic
code${tab}scalac.error
message${tab}-- Error: cyclic reference involving object Wiring" "$(printf '%s\n' "$out" | grep -E "^(kind|code|message)${tab}")"
is "scalac: that header counts it" "counts${tab}0${tab}0${tab}3${tab}1${tab}0" "$(printf '%s\n' "$out" | head -1)"
is "scalac: a -- Warning headline is scalac.warning" "code${tab}scalac.warning${tab}0${tab}1" "$(printf '[warn] -- [E198] Unused Symbol Warning: unused import\n' | fpr scalac "" | awk -F'\t' '$1=="code"{c=$0} $1=="counts"{e=$5; w=$6} END{print c "\t" e "\t" w}')"
# the floor: scalac's own `N errors found` outranks what was parsed -- one more record points at the
# raw log and the header carries N, so a headline this parser does not know can never hide an error
out=$(printf '[error] one error found\n[error] core.compile Compilation failed\n' | fpr scalac "")
is "scalac: a bare one-error-found tally is the floor record" "kind${tab}diagnostic
code${tab}scalac.error
file${tab}-
message${tab}1 errors found, 0 shown — see the raw log" "$(printf '%s\n' "$out" | grep -E "^(kind|code|file|message)${tab}")"
is "scalac: the floor header says 1 error" "counts${tab}0${tab}0${tab}2${tab}1${tab}0" "$(printf '%s\n' "$out" | head -1)"
out=$(printf '[error] a/B.scala:1:2\n  x\n  ^\nNot found: x\n[error] 2 errors found\n' | fpr scalac "")
is "scalac: 2 errors found with one positioned record appends the floor record" "2${tab}2" "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")${tab}$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5}')"
is "scalac: the floor message names both numbers" 1 "$(printf '%s\n' "$out" | grep -c "^message${tab}2 errors found, 1 shown — see the raw log\$")"
is "scalac: a tally the records already meet adds nothing" 1 "$(printf '[error] a/B.scala:1:2\n  x\n  ^\nNot found: x\n[error] one error found\n' | fpr scalac "" | grep -c "^kind${tab}diagnostic\$")"
is "scalac: the warning tally is a floor too" "code${tab}scalac.warning${tab}0${tab}1" "$(printf '[warn] 1 warning found\n' | fpr scalac "" | awk -F'\t' '$1=="code"{c=$0} $1=="counts"{e=$5; w=$6} END{print c "\t" e "\t" w}')"
# a red run with NO record and no tally: the first `[error]` line is the infra record (the reviewer's
# repro -- a scalafix config exception under a `Rewriting and linting` marker rendered as 0/0 green)
out=$(printf 'Rewriting and linting 3 Scala sources against 24 rules\n[error] core.fix scalafix.internal.config.ScalafixConfigException: Unknown rule '"'"'X'"'"'\n' | fpr auto "")
is "scalafix: an unrecognised [error] line under a marker is infra" "kind${tab}infra" "$(printf '%s\n' "$out" | grep "^kind${tab}")"
is "scalafix: … whose message is that line, bracket-stripped" "message${tab}core.fix scalafix.internal.config.ScalafixConfigException: Unknown rule 'X'" "$(printf '%s\n' "$out" | grep "^message${tab}")"
out=$(printf 'Rewriting and linting 9 Scala sources against 24 rules\n[error] core.fix A Scalafix test error was reported. Run `fix` without `--check` or `--diff` to fix the error\n' | fpr scalafix "")
is "scalafix: a Scalafix error line without a diagnostic is infra" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}infra\$")"
# with no `[error]` line either, only the exit status tells a red run from a green one
is "scalafix: a marker alone with rc 1 is unreadable" "kind${tab}unreadable" "$(printf 'Rewriting and linting 3 Scala sources against 24 rules\n' | fpr auto "" 1 | grep "^kind${tab}")"
is "scalafix: a marker alone with rc 0 is a green header" "counts${tab}0${tab}0${tab}1${tab}0${tab}0" "$(printf 'Rewriting and linting 3 Scala sources against 24 rules\n' | fpr auto "" 0)"
is "scalafix: a marker alone with no rc stays counts-only (the parser cannot tell)" "counts${tab}0${tab}0${tab}1${tab}0${tab}0" "$(printf 'Rewriting and linting 3 Scala sources against 24 rules\n' | fpr auto "")"
# an uncoded finding (`[WARNING][Rule] path:l:c text`, no `.kind`) is coded by the rule name alone
out=$(printf '[WARNING][PreferArrow] /a/b.scala:1:1 too many arrows\n' | fpr scalafix "")
is "scalafix: an uncoded finding is coded by its rule name" "code${tab}PreferArrow
message${tab}too many arrows" "$(printf '%s\n' "$out" | grep -E "^(code|message)${tab}")"
out=$(printf 'compiling 1 Scala source to out/core/compile.dest/classes ...\n[error] java.lang.OutOfMemoryError: x\n' | fpr scalac "")
is "scalac: a bracket-prefixed JVM exception is infra" "kind${tab}infra
message${tab}java.lang.OutOfMemoryError: x" "$(printf '%s\n' "$out" | grep -E "^(kind|message)${tab}")"
is "scalac: a positioned diagnostic still outranks the summary lines (no infra)" 0 "$(fpr scalac "" < "$tr_dir/scalac-notfound.txt" | grep -c "^kind${tab}infra\$")"
# the pending-rewrite header is column-0 only: an indented `--- foo.scala` is a source line
out=$(printf '[WARNING][R.k] /a/b.scala:1:1 t\n  --- foo.scala\n' | fpr scalafix "")
is "scalafix: an indented --- line is not a pending rewrite" 1 "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")"
is "scalafix: a column-0 --- header still is" 1 "$(printf '[WARNING][R.k] /a/b.scala:1:1 t\n--- foo.scala\n' | fpr scalafix "" | grep -c "^code${tab}scalafix.pending-rewrite\$")"
# message collection ends on the next `[error|warn] ` line, not only on a blank
out=$(printf '[error] a/B.scala:1:2\n  x\n  ^\nNot found: x\n[error] one error found\n[error] core.compile Compilation failed\n' | fpr scalac "")
is "scalac: a summary line closes the message without a blank" "message${tab}Not found: x" "$(printf '%s\n' "$out" | grep -E "^(message|detail)${tab}")"
is "scalac: and the closed diagnostic is no infra" "1${tab}0" "$(printf '%s\n' "$out" | awk -F'\t' '$1=="counts"{print $5 "\t" $6}')"
out=$(printf '[error] a/B.scala:1:2\n  x\n  ^\nNot found: x\n[error] a/B.scala:3:4\n  y\n  ^\nNot found: y\n\n' | fpr scalac "")
is "scalac: back-to-back diagnostics without a blank are two records" 2 "$(printf '%s\n' "$out" | grep -c "^kind${tab}diagnostic\$")"
# the existing adapters are untouched by the diagnostics-first auto-detection
is "auto: a weaver transcript is still weaver (no errors/warnings fields)" "counts${tab}1${tab}2${tab}35" "$(fp auto < "$tr_dir/weaver-scalacheck-fail.txt" | head -1)"

# --- feedback: dsh_feedback_checks -------------------------------------------------------------
fc() { /bin/sh -c '. "$1/lib.sh"; dsh_feedback_checks "$2"; printf "rc=%s\n" "$?"' _ "$engine" "$1"; }
fcroot=$(mktemp -d)
mkdir -p "$fcroot/.dsh/engine/hooks" "$fcroot/.dsh/.state" "$fcroot/app/test/src"
cp "$engine/hooks/feedback.sh" "$fcroot/.dsh/engine/hooks/feedback.sh"
printf 'app\tapp\tfmt,tests\n' > "$fcroot/.dsh/.state/modules.tsv"
: > "$fcroot/app/test/src/APros.scala"
printf 'fastTests    = ./mill -j 1 --ticker false <module>.test.testOnly -- '"'"'*Props'"'"'\nturnEndTests = ./mill -j 1 --ticker false <module>.test\n' > "$fcroot/.dsh/contract"

out=$(fc "$fcroot")
case "$out" in *FAIL*) is "feedback-checks: a clean installation has no FAIL" none "$out" ;; *) is "feedback-checks: a clean installation has no FAIL" ok ok ;; esac
case "$out" in *"rc=0"*) is "feedback-checks: exit 0 when clean" ok ok ;; *) is "feedback-checks: exit 0 when clean" ok "$out" ;; esac

# rule 2: a *Props.scala with neither forall nor Checkers
printf 'object BareProps { def x = 1 }\n' > "$fcroot/app/test/src/BareProps.scala"
out=$(fc "$fcroot")
case "$out" in *"FAIL"*"BareProps.scala"*) is "feedback-checks: rule 2 names a bare *Props.scala" ok ok ;; *) is "feedback-checks: rule 2 names a bare *Props.scala" ok "$out" ;; esac
is "feedback-checks: rule 2 does not flag the clean APros.scala decoy" 0 "$(printf '%s' "$out" | grep -c 'APros.scala')"
rm "$fcroot/app/test/src/BareProps.scala"
printf 'import weaver.scalacheck.Checkers\nobject OkProps { forall { (n: Int) => n == n } }\n' > "$fcroot/app/test/src/OkProps.scala"
out=$(fc "$fcroot")
case "$out" in *FAIL*) is "feedback-checks: a real property test (forall) does not fail rule 2" none "$out" ;; *) is "feedback-checks: a real property test (forall) does not fail rule 2" ok ok ;; esac
rm "$fcroot/app/test/src/OkProps.scala"

# rule 2 without a coverage map: nothing was judged, so a note (as holdout rule 1 says), not an ok
mv "$fcroot/.dsh/.state/modules.tsv" "$fcroot/.dsh/.state/modules.tsv.hidden"
out=$(fc "$fcroot")
is "feedback-checks: rule 2 notes an absent modules.tsv" 1 "$(printf '%s\n' "$out" | grep -c 'note.*modules.tsv.*Props.scala')"
is "feedback-checks: rule 2 claims no ok without the map" 0 "$(printf '%s\n' "$out" | grep -c 'ok.*Props.scala')"
case "$out" in *FAIL*) is "feedback-checks: an absent map never FAILs rule 2" none "$out" ;; *) is "feedback-checks: an absent map never FAILs rule 2" ok ok ;; esac
mv "$fcroot/.dsh/.state/modules.tsv.hidden" "$fcroot/.dsh/.state/modules.tsv"

# rule 1: the wrapper missing
mv "$fcroot/.dsh/engine/hooks/feedback.sh" "$fcroot/.dsh/engine/hooks/feedback.sh.hidden"
out=$(fc "$fcroot")
case "$out" in *"FAIL"*"feedback.sh"*) is "feedback-checks: rule 1 fails when the wrapper is missing" ok ok ;; *) is "feedback-checks: rule 1 fails when the wrapper is missing" ok "$out" ;; esac
mv "$fcroot/.dsh/engine/hooks/feedback.sh.hidden" "$fcroot/.dsh/engine/hooks/feedback.sh"

# rule 3: no contract keys -> two notes, no FAIL
: > "$fcroot/.dsh/contract"
out=$(fc "$fcroot")
is "feedback-checks: rule 3 notes an absent fastTests" 1 "$(printf '%s\n' "$out" | grep -c 'note.*fastTests')"
is "feedback-checks: rule 3 notes an absent turnEndTests" 1 "$(printf '%s\n' "$out" | grep -c 'note.*turnEndTests')"
case "$out" in *FAIL*) is "feedback-checks: absent contract keys never FAIL" none "$out" ;; *) is "feedback-checks: absent contract keys never FAIL" ok ok ;; esac
printf 'fastTests    = ./mill -j 1 --ticker false <module>.test.testOnly -- '"'"'*Props'"'"'\nturnEndTests = ./mill -j 1 --ticker false <module>.test\n' > "$fcroot/.dsh/contract"

# rule 4: a draft file awaiting promotion
mkdir -p "$fcroot/app/test-draft/src/x"
: > "$fcroot/app/test-draft/src/x/DraftProps.scala"
out=$(fc "$fcroot")
case "$out" in *"note"*"DraftProps.scala"*) is "feedback-checks: rule 4 names a file under test-draft/src" ok ok ;; *) is "feedback-checks: rule 4 names a file under test-draft/src" ok "$out" ;; esac
rm -rf "$fcroot/app/test-draft"

# rule 5: more than 20 logs
mkdir -p "$fcroot/.dsh/.state/feedback"
i=0; while [ $i -lt 21 ]; do : > "$fcroot/.dsh/.state/feedback/log$i.log"; i=$((i + 1)); done
out=$(fc "$fcroot")
case "$out" in *"note"*"21 feedback logs"*) is "feedback-checks: rule 5 notes more than 20 logs" ok ok ;; *) is "feedback-checks: rule 5 notes more than 20 logs" ok "$out" ;; esac
rm -rf "$fcroot/.dsh/.state/feedback"

# rules 2 and 4 scan through dsh_find_pruned -- .dsh/engine/tests/cases/*/root/** fixture trees are not
# the project, and must never surface a permanent note/FAIL of their own.
mkdir -p "$fcroot/.dsh/engine/tests/cases/x/root/app/test-draft/src"
: > "$fcroot/.dsh/engine/tests/cases/x/root/app/test-draft/src/P.scala"
mkdir -p "$fcroot/.dsh/engine/tests/cases/x/root/app/test/src"
printf 'object BadProps { def x = 1 }\n' > "$fcroot/.dsh/engine/tests/cases/x/root/app/test/src/BadProps.scala"
out=$(fc "$fcroot")
is "feedback-checks: rule 4 ignores a draft under a .dsh/engine/tests/cases fixture tree" 0 "$(printf '%s' "$out" | grep -c 'P.scala')"
case "$out" in *FAIL*) is "feedback-checks: rule 2 ignores a bare Props under a .dsh/engine/tests/cases fixture tree" none "$out" ;; *) is "feedback-checks: rule 2 ignores a bare Props under a .dsh/engine/tests/cases fixture tree" ok ok ;; esac
rm -rf "$fcroot/.dsh/engine/tests/cases"

# the identical files OUTSIDE .dsh/ still trigger both rules -- the pruning is scoped to the
# harness's own trees, not to *Props.scala / test-draft/src in general.
mkdir -p "$fcroot/other/test-draft/src"
: > "$fcroot/other/test-draft/src/P.scala"
mkdir -p "$fcroot/other/test/src"
printf 'object BadProps { def x = 1 }\n' > "$fcroot/other/test/src/BadProps.scala"
printf 'other\tother\tfmt,tests\n' >> "$fcroot/.dsh/.state/modules.tsv"
out=$(fc "$fcroot")
case "$out" in *"note"*"P.scala"*) is "feedback-checks: rule 4 still names a draft outside .dsh/" ok ok ;; *) is "feedback-checks: rule 4 still names a draft outside .dsh/" ok "$out" ;; esac
case "$out" in *"FAIL"*"BadProps.scala"*) is "feedback-checks: rule 2 still fails a bare Props outside .dsh/" ok ok ;; *) is "feedback-checks: rule 2 still fails a bare Props outside .dsh/" ok "$out" ;; esac
rm -rf "$fcroot/other"
sed -i.bak '/^other/d' "$fcroot/.dsh/.state/modules.tsv"

is "feedback-checks: every row has a leading ok|FAIL|note|rc= tag" 0 "$(fc "$fcroot" | grep -Evc '^(ok|FAIL|note|rc=)')"
rm -rf "$fcroot"

# --- instructions: dsh_instruction_for ------------------------------------------------------------
ifor() { /bin/sh -c '. "$1/lib.sh"; dsh_instruction_for "$2" "$3"' _ "$engine" "$1" "$2"; }
iroot=$(mktemp -d); mkdir -p "$iroot/.dsh/instructions"
printf '# purrism 0.9.1\nPreferEffectIdioms.manual-resource\tPreferEffectIdioms\tT\tE\tWrap it in Resource.make\thttps://x/#effects\nPreferArrow.readability-budget\tPreferArrow\tT\tE\tKeep the arrow chain short\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
printf '# local\nscalac.not-found\tscalac\tT\tE\tCheck the spelling\t\nPreferArrow.readability-budget\tPreferArrow\tT\tE\tLOCAL OVERRIDE\t\n' > "$iroot/.dsh/instructions/local.tsv"
is "instruction: found in purrism.tsv" "Wrap it in Resource.make${tab}https://x/#effects" "$(ifor PreferEffectIdioms.manual-resource "$iroot")"
is "instruction: local.tsv wins on a duplicate code" "LOCAL OVERRIDE${tab}" "$(ifor PreferArrow.readability-budget "$iroot")"
is "instruction: found in local.tsv" "Check the spelling${tab}" "$(ifor scalac.not-found "$iroot")"
is "instruction: kind fallback for an umbrella/alias prefix" "Wrap it in Resource.make${tab}https://x/#effects" "$(ifor TypelevelPurrism.manual-resource "$iroot")"
is "instruction: unknown code prints nothing" "" "$(ifor Nope.nothing "$iroot")"
ifor Nope.nothing "$iroot" >/dev/null; is "instruction: unknown code returns 1" 1 "$?"
printf '# local\nbroken row without tabs\n' > "$iroot/.dsh/instructions/local.tsv"
is "instruction: a malformed local row is skipped, purrism still answers" "Wrap it in Resource.make${tab}https://x/#effects" "$(ifor PreferEffectIdioms.manual-resource "$iroot")"
# BSD awk aborts on the first unreadable file: a missing local.tsv must not hide every purrism row
rm "$iroot/.dsh/instructions/local.tsv"
is "instruction: a purrism-only root (no local.tsv) still answers" "Wrap it in Resource.make${tab}https://x/#effects" "$(ifor PreferEffectIdioms.manual-resource "$iroot")"
rm "$iroot/.dsh/instructions/purrism.tsv"
ifor PreferEffectIdioms.manual-resource "$iroot" >/dev/null; is "instruction: no table at all returns 1" 1 "$?"
rm -r "$iroot"

# --- instructions: dsh_purrism_declared_version ----------------------------------------------------
pver() { /bin/sh -c '. "$1/lib.sh"; dsh_purrism_declared_version "$2"' _ "$engine" "$1"; }
vroot=$(mktemp -d); mkdir -p "$vroot/buildKit"
printf 'trait Layer {\n  def scalafixIvyDeps = Seq(\n    mvn"io.github.mercurievv:scala-purrism-scalafix_3:0.9.1",\n    mvn"io.github.mercurievv:scala-purrism-scalafix_3:9.9.9",\n  )\n}\n' > "$vroot/buildKit/Layer.mill"
is "purrism-version: the first literal in buildKit/Layer.mill" "0.9.1" "$(pver "$vroot")"
printf 'trait Layer {}\n' > "$vroot/buildKit/Layer.mill"
is "purrism-version: no literal prints nothing" "" "$(pver "$vroot")"
pver "$vroot" >/dev/null; is "purrism-version: no literal returns 1" 1 "$?"
rm "$vroot/buildKit/Layer.mill"
pver "$vroot" >/dev/null 2>&1; is "purrism-version: no Layer.mill returns 1" 1 "$?"
rm -r "$vroot"

# --- dsh_check_through_wrapper: the shared "run one check through the wrapper" step -------------
# A stub Mill in a scratch root (gate_root, so the wrapper's log lands there); `here` is this repo's
# .dsh, as both hooks set it. The fixtures (run.sh) drive the same step end to end through the gates.
wroot=$(mktemp -d); mkdir -p "$wroot/.dsh/.state" "$wroot/.dsh/instructions"
printf '# local\n' > "$wroot/.dsh/instructions/local.tsv"; printf '# purrism 0.9.1\n' > "$wroot/.dsh/instructions/purrism.tsv"
printf '#!/bin/sh\ncase "$*" in *red*) printf "[error] app.compile Compilation failed\\n"; exit 1 ;; *diag*) printf "[error] a/B.scala:1:2\\n  x\\n  ^\\nNot found: x\\n"; exit 1 ;; esac\nprintf "done compiling\\n"\n' > "$wroot/mill"; chmod +x "$wroot/mill"
cw() { GATE_ROOT="$wroot" /bin/sh -c 'here="$1"; . "$1/lib.sh"; dsh_check_through_wrapper "$2" "$3" "$2"; printf "rc=%s\\n--shown--\\n%s\\n--raw--\\n%s\\n" "$DSH_CHECK_RC" "$DSH_CHECK_SHOWN" "$DSH_CHECK_RAW"' _ "$engine" "$1" "$wroot/mill"; }
out=$(cw app.green)
is "check-wrapper: a green check returns rc 0" 1 "$(printf '%s\n' "$out" | grep -c '^rc=0$')"
out=$(cw app.red)
is "check-wrapper: rc is the command's" 1 "$(printf '%s\n' "$out" | grep -c '^rc=1$')"
is "check-wrapper: INFRA falls back to the raw text (no INFRA: line reaches the agent)" 0 "$(printf '%s\n' "$out" | grep -c 'INFRA:')"
is "check-wrapper: the raw text is the log Mill printed" 2 "$(printf '%s\n' "$out" | grep -c '^\[error\] app.compile Compilation failed$')"
out=$(cw app.diag)
is "check-wrapper: a diagnostic run shows the rendered block" 1 "$(printf '%s\n' "$out" | grep -c '^DIAGNOSTIC: a/B.scala:1:2 \[scalac.error\] Not found: x$')"
is "check-wrapper: … and keeps the raw log apart for attribution" 1 "$(printf '%s\n' "$out" | sed -n '/^--raw--$/,$p' | grep -c '^Not found: x$')"
rm -r "$wroot"

# --- instructions: annotate + render -------------------------------------------------------------
iroot=$(mktemp -d); mkdir -p "$iroot/.dsh/instructions"
printf '# purrism 0.9.1\nPreferEffectIdioms.manual-resource\tPreferEffectIdioms\tT\tE\tWrap it in Resource.make\thttps://x/#effects\n' > "$iroot/.dsh/instructions/purrism.tsv"
printf '# local\n' > "$iroot/.dsh/instructions/local.tsv"
stream=$(printf 'counts\t0\t0\t9\t1\t1\nkind\tdiagnostic\nsource\tscalafix\ncode\tPreferEffectIdioms.manual-resource\nfile\tcore/src/A.scala:8:5\nmessage\tManual acquire/release\n\nkind\tdiagnostic\nsource\tscalac\ncode\tscalac.type-mismatch\nfile\tcore/src/B.scala:7:26\nmessage\tFound:    (42 : Int)\ndetail\tRequired: String\n\n')
ann=$(printf '%s\n' "$stream" | /bin/sh -c '. "$1/lib.sh"; dsh_instructions_annotate "$2" "$3"' _ "$engine" "$iroot" "$iroot/missing")
is "annotate: instruction row follows the code row" "code${tab}PreferEffectIdioms.manual-resource
instruction${tab}Wrap it in Resource.make
doc${tab}https://x/#effects" "$(printf '%s\n' "$ann" | grep -A2 "^code${tab}PreferEffect")"
is "annotate: the unmatched code is recorded once" "scalac.type-mismatch" "$(cat "$iroot/missing")"
printf '%s\n' "$stream" | /bin/sh -c '. "$1/lib.sh"; dsh_instructions_annotate "$2" "$3"' _ "$engine" "$iroot" "$iroot/missing" >/dev/null
is "annotate: missing file is deduped across runs" 1 "$(wc -l < "$iroot/missing" | tr -d ' ')"
rend=$(printf '%s\n' "$ann" | rf "core.fixStrict" ".dsh/.state/feedback/x.log")
is "render: diagnostics header" "FEEDBACK: 1 errors, 1 warnings (core.fixStrict)" "$(printf '%s\n' "$rend" | sed -n 1p)"
is "render: DIAGNOSTIC line" "DIAGNOSTIC: core/src/A.scala:8:5 [PreferEffectIdioms.manual-resource] Manual acquire/release" "$(printf '%s\n' "$rend" | sed -n 2p)"
is "render: INSTRUCTION and DOC indented" "  INSTRUCTION: Wrap it in Resource.make
  DOC: https://x/#effects" "$(printf '%s\n' "$rend" | sed -n 3,4p)"
is "render: detail row indented under the scalac diagnostic" "  Required: String" "$(printf '%s\n' "$rend" | grep '^  Required')"
is "render: the gap line" "No instruction for: scalac.type-mismatch" "$(printf '%s\n' "$rend" | grep '^No instruction')"
is "render: raw line still last" 1 "$(printf '%s\n' "$rend" | tail -1 | grep -c '^Raw output')"
green=$(printf 'counts\t0\t0\t2\t0\t0\n' | rf "core.compile" "l.log")
is "render: a green diagnostics run is one line" "FEEDBACK: 0 errors, 0 warnings (core.compile)" "$green"
rm -r "$iroot"

# --- instructions: dsh_instruction_checks ----------------------------------------------------------
ichk() { /bin/sh -c '. "$1/lib.sh"; dsh_instruction_checks "$2"' _ "$engine" "$1"; }
iroot=$(mktemp -d); mkdir -p "$iroot/.dsh/instructions" "$iroot/.dsh/.state" "$iroot/buildKit"
printf 'mvn"io.github.mercurievv:scala-purrism-scalafix_3:0.9.1",\n' > "$iroot/buildKit/Layer.mill"
printf '# purrism 0.9.1\nA.b\tA\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
printf '# local\nscalac.not-found\tscalac\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/local.tsv"
printf 'not-found\t^Not found: \n' > "$iroot/.dsh/instructions/scalac-kinds.tsv"
mkdir -p "$iroot/.dsh/engine"; : > "$iroot/.dsh/engine/instructions-sync.sh"
printf '.dsh/instructions/purrism.tsv\tx\n.dsh/instructions/local.tsv\tx\n.dsh/instructions/scalac-kinds.tsv\tx\n.dsh/engine/instructions-sync.sh\tx\n' > "$iroot/.dsh/frozen-paths"
is "ichecks: a well-formed installation is all ok" 0 "$(ichk "$iroot" | grep -c "^FAIL")"
printf '# purrism 0.9.1\nA.b\tA\tT\n' > "$iroot/.dsh/instructions/purrism.tsv"
is "ichecks: rule 1 — a purrism row that is not six fields FAILs" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*purrism.tsv.*six")"
printf 'A.b\tA\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
is "ichecks: rule 1 — a table without the # purrism header FAILs" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*purrism.tsv has no .# purrism <version>. header")"
printf '# purrism 0.9.1\nA.b\tA\tT\tE\tI\t\nA.b\tA\tT2\tE2\tI2\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
is "ichecks: rule 1 — a duplicate code FAILs and is named" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*purrism.tsv: duplicate code(s): A.b")"
printf '# purrism 0.9.0\nA.b\tA\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
is "ichecks: rule 2 — header/build version mismatch FAILs and names the remedy" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*0.9.0.*0.9.1.*instructions-sync.sh")"
printf '# purrism 0.9.1\nA.b\tA\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/purrism.tsv"
printf '# local\nnodot\tscalac\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/local.tsv"
is "ichecks: rule 3 — a local code without <rule>.<kind> FAILs" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*local.tsv.*nodot")"
printf '# local\nscalac.not-found\tscalac\tT\tE\tI\t\n' > "$iroot/.dsh/instructions/local.tsv"
printf 'type-mismatch\t^Found: \n' > "$iroot/.dsh/instructions/scalac-kinds.tsv"
is "ichecks: rule 3 — a kind with no scalac.<kind> row FAILs" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*type-mismatch")"
printf 'not-found\t^Not found: \n' > "$iroot/.dsh/instructions/scalac-kinds.tsv"
printf 'PreferArrow.readability-budget\n' > "$iroot/.dsh/.state/instructions-missing"
is "ichecks: rule 4 — the backlog is a note naming the code" 1 "$(ichk "$iroot" | grep -c "^note${tab}.*PreferArrow.readability-budget")"
printf '.dsh/instructions/purrism.tsv\tx\n' > "$iroot/.dsh/frozen-paths"
is "ichecks: rule 5 — an unfrozen table FAILs" 1 "$(ichk "$iroot" | grep -c "^FAIL${tab}.*not frozen.*local.tsv")"
rm -r "$iroot"

# --- dsh_diff_ranges: git diff -U0 hunk headers to 0-based half-open ranges ------------
vr_tmp=$(mktemp -d)
cat > "$vr_tmp/d1" <<'DIFF'
diff --git a/core/src/A.scala b/core/src/A.scala
--- a/core/src/A.scala
+++ b/core/src/A.scala
@@ -41,0 +42,3 @@ object A:
+  val x = 1
+  val y = 2
+  val z = 3
DIFF
dsh_diff_ranges "$vr_tmp/d1" "$vr_tmp/o1"
is "dsh_diff_ranges: a three-line hunk is one 0-based half-open range" \
  "core/src/A.scala	41	44" "$(cat "$vr_tmp/o1")"

cat > "$vr_tmp/d2" <<'DIFF'
diff --git a/core/src/B.scala b/core/src/B.scala
--- a/core/src/B.scala
+++ b/core/src/B.scala
@@ -7 +7 @@ object B:
-  val old = 1
+  val now = 1
DIFF
dsh_diff_ranges "$vr_tmp/d2" "$vr_tmp/o2"
is "dsh_diff_ranges: a -U0 single-line hunk has no comma and counts 1" \
  "core/src/B.scala	6	7" "$(cat "$vr_tmp/o2")"

cat > "$vr_tmp/d3" <<'DIFF'
diff --git a/core/src/C.scala b/core/src/C.scala
new file mode 100644
--- /dev/null
+++ b/core/src/C.scala
@@ -0,0 +1,5 @@
+package p
+object C:
+  val a = 1
+  val b = 2
+  val c = 3
DIFF
dsh_diff_ranges "$vr_tmp/d3" "$vr_tmp/o3"
is "dsh_diff_ranges: a new file is one range from 0" \
  "core/src/C.scala	0	5" "$(cat "$vr_tmp/o3")"

cat > "$vr_tmp/d4" <<'DIFF'
diff --git a/core/src/D.scala b/core/src/D.scala
--- a/core/src/D.scala
+++ b/core/src/D.scala
@@ -10,3 +9,0 @@ object D:
-  val gone = 1
-  val also = 2
-  val too = 3
DIFF
dsh_diff_ranges "$vr_tmp/d4" "$vr_tmp/o4"
is "dsh_diff_ranges: a pure deletion contributes no range" "" "$(cat "$vr_tmp/o4")"

cat > "$vr_tmp/d5" <<'DIFF'
diff --git a/core/src/E.scala b/core/src/E.scala
--- a/core/src/E.scala
+++ b/core/src/E.scala
@@ -3,0 +4 @@ object E:
+  val one = 1
@@ -20,0 +22,2 @@ object E:
+  val two = 2
+  val three = 3
diff --git a/core/src/F.scala b/core/src/F.scala
--- a/core/src/F.scala
+++ b/core/src/F.scala
@@ -1,0 +2 @@
+  val f = 1
DIFF
dsh_diff_ranges "$vr_tmp/d5" "$vr_tmp/o5"
is "dsh_diff_ranges: two hunks in one file and a second file are four fields per row" \
  "core/src/E.scala	3	4
core/src/E.scala	21	23
core/src/F.scala	1	2" "$(cat "$vr_tmp/o5")"

cat > "$vr_tmp/d6" <<'DIFF'
diff --git a/old.scala b/old.scala
deleted file mode 100644
--- a/old.scala
+++ /dev/null
@@ -1,3 +0,0 @@
-package p
-object O
-// gone
DIFF
dsh_diff_ranges "$vr_tmp/d6" "$vr_tmp/o6"
is "dsh_diff_ranges: a deleted file contributes nothing" "" "$(cat "$vr_tmp/o6")"

: > "$vr_tmp/d7"
dsh_diff_ranges "$vr_tmp/d7" "$vr_tmp/o7"
is "dsh_diff_ranges: an empty diff writes an empty file" "" "$(cat "$vr_tmp/o7")"
rm -rf "$vr_tmp"

# --- dsh_diff_coordinates: coordinates added to a build file --------------------------
vc_tmp=$(mktemp -d)
cat > "$vc_tmp/d1" <<'DIFF'
diff --git a/build.mill b/build.mill
--- a/build.mill
+++ b/build.mill
@@ -10,0 +11,2 @@ object core extends ScalaModule:
+    mvn"org.typelevel::cats-effect:3.6.1",
+    mvn"org.postgresql:postgresql:42.7.3",
DIFF
is "dsh_diff_coordinates: mvn\"\" with :: and with : " \
  "org.postgresql:postgresql:42.7.3
org.typelevel::cats-effect:3.6.1" "$(dsh_diff_coordinates "$vc_tmp/d1")"

cat > "$vc_tmp/d2" <<'DIFF'
diff --git a/project/Deps.sbt b/project/Deps.sbt
--- a/project/Deps.sbt
+++ b/project/Deps.sbt
@@ -3,0 +4,2 @@
+  "org.typelevel" %% "cats" % "2.13.0",
+  "com.h2database" % "h2" % "2.2.224",
DIFF
is "dsh_diff_coordinates: sbt %% and % spellings" \
  "com.h2database:h2:2.2.224
org.typelevel::cats:2.13.0" "$(dsh_diff_coordinates "$vc_tmp/d2")"

cat > "$vc_tmp/d3" <<'DIFF'
diff --git a/build.mill b/build.mill
--- a/build.mill
+++ b/build.mill
@@ -10,2 +10,2 @@ object core extends ScalaModule:
-    mvn"org.typelevel::cats-effect:3.5.0",
+    mvn"org.typelevel::cats-effect:3.6.1",
DIFF
is "dsh_diff_coordinates: only + lines count, the removed version is not reported" \
  "org.typelevel::cats-effect:3.6.1" "$(dsh_diff_coordinates "$vc_tmp/d3")"

cat > "$vc_tmp/d4" <<'DIFF'
diff --git a/core/src/A.scala b/core/src/A.scala
--- a/core/src/A.scala
+++ b/core/src/A.scala
@@ -1,0 +2 @@
+  val s = "org.typelevel::cats-effect:3.6.1"
DIFF
is "dsh_diff_coordinates: a Scala source is not a build file" "" "$(dsh_diff_coordinates "$vc_tmp/d4")"

cat > "$vc_tmp/d5" <<'DIFF'
diff --git a/build.mill b/build.mill
--- a/build.mill
+++ b/build.mill
@@ -10,0 +11,2 @@
+    mvn"org.typelevel::cats-effect:3.6.1",
+    mvn"org.typelevel::cats-effect:3.6.1",
DIFF
is "dsh_diff_coordinates: the same coordinate twice is reported once" \
  "org.typelevel::cats-effect:3.6.1" "$(dsh_diff_coordinates "$vc_tmp/d5")"

: > "$vc_tmp/d6"
is "dsh_diff_coordinates: an empty diff yields nothing" "" "$(dsh_diff_coordinates "$vc_tmp/d6")"
rm -rf "$vc_tmp"

# --- dsh_policy_allows: the module's allowed symbol prefixes ---------------------------
vp_tmp=$(mktemp -d)
mkdir -p "$vp_tmp/.dsh/policy"
cat > "$vp_tmp/.dsh/policy/allowed-types.tsv" <<'TSV'
# <module dir> TAB <allowed symbol prefix> TAB <reason>
engine/shape	skreeep2/engine/shape/	the shape layer names only its own types
engine/shape	skreeep2/engine/api/	the shape layer may speak the published api
engine/details	skreeep2/	the details layer may name anything in the project
TSV
is "dsh_policy_allows: a symbol under an allowed prefix is allowed" 0 \
  "$(dsh_policy_allows 'skreeep2/engine/shape/Box#' engine/shape "$vp_tmp" >/dev/null; echo $?)"
is "dsh_policy_allows: a second prefix for the same module is allowed too" 0 \
  "$(dsh_policy_allows 'skreeep2/engine/api/Port#' engine/shape "$vp_tmp" >/dev/null; echo $?)"
is "dsh_policy_allows: a symbol under no prefix is refused" 1 \
  "$(dsh_policy_allows 'skreeep2/engine/details/Impl#' engine/shape "$vp_tmp" >/dev/null; echo $?)"
is "dsh_policy_allows: the refusal prints the row's reason" \
  "the shape layer names only its own types" \
  "$(dsh_policy_allows 'skreeep2/engine/details/Impl#' engine/shape "$vp_tmp")"
is "dsh_policy_allows: a module with no rows has no policy" 0 \
  "$(dsh_policy_allows 'anything/at/All#' wiring/arhitecture "$vp_tmp" >/dev/null; echo $?)"
is "dsh_policy_allows: with no table at all, everything is allowed" 0 \
  "$(dsh_policy_allows 'skreeep2/engine/details/Impl#' engine/shape "$vp_tmp/nope" >/dev/null; echo $?)"
is "dsh_policy_allows: a prefix is a prefix, not a substring" 1 \
  "$(dsh_policy_allows 'other/skreeep2/engine/shape/Box#' engine/shape "$vp_tmp" >/dev/null; echo $?)"
rm -rf "$vp_tmp"

# --- dsh_verify_checks: the installation rules -----------------------------------------
vk_tmp=$(mktemp -d)
mkdir -p "$vk_tmp/.dsh/policy"
vk_rows=$(dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: a missing verify-diff.sh is a FAIL" "FAIL" "$vk_rows"
has "dsh_verify_checks: it names the script" "verify-diff.sh" "$vk_rows"
# A project in the vendored layout, built here so the engine's tests carry no project's state: the
# engine at .dsh/engine/, a policy table and a memorisation table, all three frozen.
self_root=$(mktemp -d)
mkdir -p "$self_root/.dsh/engine" "$self_root/.dsh/policy"
cp -p "$engine/verify-diff.sh" "$self_root/.dsh/engine/verify-diff.sh"
printf 'engine/shape\tscala/\tthe standard library\n' > "$self_root/.dsh/policy/allowed-types.tsv"
printf 'min_overlap\t8\n' > "$self_root/.dsh/policy/memorisation.tsv"
printf '.dsh/engine/verify-diff.sh\tthe gate is the human'"'"'s\n.dsh/policy/allowed-types.tsv\tthe policy is the human'"'"'s\n.dsh/policy/memorisation.tsv\tthe thresholds are the human'"'"'s\n' > "$self_root/.dsh/frozen-paths"
vk_self=$(dsh_verify_checks "$self_root" 2>&1)
has "dsh_verify_checks: this repository's script is present" "ok	.dsh/engine/verify-diff.sh is present and executable" "$vk_self"
has "dsh_verify_checks: this repository's policy table parses" ".dsh/policy/allowed-types.tsv" "$vk_self"
has "dsh_verify_checks: it reports whether the script and the table are frozen" "frozen" "$vk_self"
# An EMPTY policy table is the same state as no table at all -- no module has a policy, none is
# enforced -- so it must not read as `ok ... (0 rule row(s))`, which sounds like a policy is in force.
: > "$vk_tmp/.dsh/policy/allowed-types.tsv"
vk_empty=$(dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: an empty policy table is a note, not an ok" \
  "note	.dsh/policy/allowed-types.tsv has no rule rows" "$vk_empty"
# The launcher probe and the classpath check are INDEPENDENT facts and are reported independently:
# the probe used to sit behind the classpath test, so on a machine with a stale jar AND no classpath
# (the very machine that motivated it) it never ran.
mkdir -p "$vk_tmp/bin"
vk_l="$vk_tmp/bin/scalasemantic-mcp"

# A launcher older than the one-shot `call` mode falls through to `serve`, reads EOF on the closed
# stdin and exits 0 printing nothing on stdout -- only the JVM's own WARNING lines on stderr. That is
# the configuration that caused the silent pass, so it must not report `ok`.
printf '#!/bin/sh\nprintf "WARNING: A terminally deprecated method in sun.misc.Unsafe has been called\\n" >&2\nexit 0\n' > "$vk_l"
chmod +x "$vk_l"
vk_old=$(SCALASEMANTIC_MCP_LAUNCHER="$vk_l" dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: a launcher that does not answer \`call\` is a note" \
  "answers nothing to \`call resolve_references\`" "$vk_old"
has "dsh_verify_checks: the stale-launcher probe runs even with no classpath metadata" \
  "answers nothing to \`call resolve_references\`" "$vk_old"

# A CURRENT launcher, measured: it REJECTS the probe's empty `files` list with rc 1, EMPTY stdout, and
# the rejection on stderr beneath the same JVM WARNING lines. It must read as a launcher that has
# `call`, not as a stale one -- keying on stdout alone reported every current launcher as stale.
printf '#!/bin/sh\nprintf "WARNING: A terminally deprecated method in sun.misc.Unsafe has been called\\n" >&2\nprintf "resolve_references failed: java.lang.RuntimeException: resolve_references: \\`files\\` must hold at least one {uri, ranges} object\\n" >&2\nexit 1\n' > "$vk_l"
chmod +x "$vk_l"
vk_cur=$(SCALASEMANTIC_MCP_LAUNCHER="$vk_l" dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: a current launcher that rejects the probe on stderr answers \`call\`" \
  "ok	the launcher answers \`call resolve_references\`" "$vk_cur"
case "$vk_cur" in
  *'answers nothing to `call'*) bad "dsh_verify_checks: a current launcher must not be reported stale: [$vk_cur]" ;;
  *) ok "dsh_verify_checks: a current launcher is not reported stale" ;;
esac

# ... and one that answers on stdout is fine too.
printf '#!/bin/sh\nprintf %%s \x27{"files":[]}\x27\n' > "$vk_l"
chmod +x "$vk_l"
vk_new=$(SCALASEMANTIC_MCP_LAUNCHER="$vk_l" dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: a launcher that answers \`call\` on stdout is ok" \
  "ok	the launcher answers \`call resolve_references\`" "$vk_new"

# The server DISCOVERS its classpath from .scala-semantic/classpath-<tool>.json under the root; there
# is no harness-side classpath file. Absent metadata is a note naming what to generate.
has "dsh_verify_checks: no classpath metadata is a note naming it" \
  ".scala-semantic/classpath-" "$vk_new"
mkdir -p "$vk_tmp/.scala-semantic"
printf '{}\n' > "$vk_tmp/.scala-semantic/classpath-mill.json"
vk_cp=$(SCALASEMANTIC_MCP_LAUNCHER="$vk_l" dsh_verify_checks "$vk_tmp" 2>&1)
has "dsh_verify_checks: classpath metadata present is ok" \
  "ok	classpath metadata found" "$vk_cp"
case "$vk_cp" in
  *'.dsh/.state/classpath'*) bad "dsh_verify_checks: the retired .dsh/.state/classpath is still named: [$vk_cp]" ;;
  *) ok "dsh_verify_checks: the retired .dsh/.state/classpath is not named" ;;
esac
rm -rf "$vk_tmp"

# --- dsh_memo_judge: overlap between a construct's literals and the tests' literals -----------
mj_tmp=$(mktemp -d)
mkdir -p "$mj_tmp/.dsh/policy"
mj_prod() { # rows: key value touched — all in core/src/T.scala, all kind string
  : > "$mj_tmp/prod.tsv"
  while [ $# -ge 3 ]; do
    printf 'core/src/T.scala\t%s\tstring\t%s\t%s\n' "$1" "$2" "$3" >> "$mj_tmp/prod.tsv"
    shift 3
  done
}
printf '%s\n' k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 > "$mj_tmp/test.txt"

# 10 keys, all test inputs -> flagged (k=10 >= 8, ratio 1.0)
mj_prod val:table:3 k1 1 val:table:3 k2 0 val:table:3 k3 0 val:table:3 k4 0 val:table:3 k5 0 \
        val:table:3 k6 0 val:table:3 k7 0 val:table:3 k8 0 val:table:3 k9 0 val:table:3 k10 0
has "dsh_memo_judge: a table whose keys are the test inputs is flagged" \
  "core/src/T.scala	val:table:3	10	10" "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# the same table, never touched this turn -> not judged
mj_prod val:table:3 k1 0 val:table:3 k2 0 val:table:3 k3 0 val:table:3 k4 0 val:table:3 k5 0 \
        val:table:3 k6 0 val:table:3 k7 0 val:table:3 k8 0 val:table:3 k9 0 val:table:3 k10 0
is "dsh_memo_judge: an untouched construct is never judged" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# k >= 8 but ratio < 0.5 -> not flagged (8 overlaps among 20 literals)
mj_prod val:t:1 k1 1 val:t:1 k2 0 val:t:1 k3 0 val:t:1 k4 0 val:t:1 k5 0 val:t:1 k6 0 val:t:1 k7 0 val:t:1 k8 0 \
        val:t:1 x01 0 val:t:1 x02 0 val:t:1 x03 0 val:t:1 x04 0 val:t:1 x05 0 val:t:1 x06 0 \
        val:t:1 x07 0 val:t:1 x08 0 val:t:1 x09 0 val:t:1 x10 0 val:t:1 x11 0 val:t:1 x12 0
is "dsh_memo_judge: k >= 8 with a low ratio is not enough" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# ratio 1.0 but k < 8 -> not flagged
mj_prod val:t:1 k1 1 val:t:1 k2 0 val:t:1 k3 0
is "dsh_memo_judge: a high ratio with k < 8 is not enough" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# a table grown in small steps: only its newest row is touched, but the whole construct is judged
mj_prod val:table:3 k1 0 val:table:3 k2 0 val:table:3 k3 0 val:table:3 k4 0 val:table:3 k5 0 \
        val:table:3 k6 0 val:table:3 k7 0 val:table:3 k8 1
has "dsh_memo_judge: a table grown row by row is judged whole once touched" \
  "val:table:3	8	8" "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# trivial literals are dropped before counting
printf '%s\n' 0 1 2 3 4 5 6 7 8 9 a b > "$mj_tmp/triv.txt"
: > "$mj_tmp/prod.tsv"
for v in 0 1 2 3 4 5 6 7 8 9; do printf 'core/src/T.scala\tdef:f:1\tint\t%s\t1\n' "$v" >> "$mj_tmp/prod.tsv"; done
for v in a b; do printf 'core/src/T.scala\tdef:f:1\tstring\t%s\t1\n' "$v" >> "$mj_tmp/prod.tsv"; done
is "dsh_memo_judge: small numbers and one-character strings are trivial" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/triv.txt" "$mj_tmp")"

# constructs in different files are judged separately (Review Focus 2)
: > "$mj_tmp/prod.tsv"
for v in k1 k2 k3 k4 k5; do printf 'core/src/A.scala\tval:t:1\tstring\t%s\t1\n' "$v" >> "$mj_tmp/prod.tsv"; done
for v in k6 k7 k8 k9 k10; do printf 'core/src/B.scala\tval:t:1\tstring\t%s\t1\n' "$v" >> "$mj_tmp/prod.tsv"; done
is "dsh_memo_judge: constructs in different files are judged separately" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# occurrences count (Review Focus 4): 4 distinct test keys, each written twice -> k=8, n=8
mj_prod val:t:1 k1 1 val:t:1 k1 0 val:t:1 k2 0 val:t:1 k2 0 val:t:1 k3 0 val:t:1 k3 0 val:t:1 k4 0 val:t:1 k4 0
has "dsh_memo_judge: a repeated test value counts once per occurrence" \
  "val:t:1	8	8" "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"

# an allow row exempts the construct
printf 'core/src/T.scala\tval:table:3\tthe MIDI note table; its keys are the standard names\n' \
  > "$mj_tmp/.dsh/policy/memorisation.tsv"
mj_prod val:table:3 k1 1 val:table:3 k2 0 val:table:3 k3 0 val:table:3 k4 0 val:table:3 k5 0 \
        val:table:3 k6 0 val:table:3 k7 0 val:table:3 k8 0 val:table:3 k9 0 val:table:3 k10 0
is "dsh_memo_judge: an allow row exempts the construct" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/test.txt" "$mj_tmp")"
is "dsh_memo_allowed: an allow row answers with its reason" \
  "the MIDI note table; its keys are the standard names" \
  "$(dsh_memo_allowed core/src/T.scala val:table:3 "$mj_tmp")"

# thresholds come from the policy table, with defaults
is "dsh_memo_policy: default min_overlap" 8 "$(dsh_memo_policy min_overlap "$mj_tmp")"
printf 'min_overlap\t3\n' >> "$mj_tmp/.dsh/policy/memorisation.tsv"
is "dsh_memo_policy: a policy row overrides the default" 3 "$(dsh_memo_policy min_overlap "$mj_tmp")"

# an empty test-values file means nothing overlaps (the NR == FNR trap: an empty FIRST file makes
# awk read the second file as the first, so this must be guarded before awk ever runs)
: > "$mj_tmp/empty.txt"
is "dsh_memo_judge: no test literals means nothing overlaps" "" \
  "$(dsh_memo_judge "$mj_tmp/prod.tsv" "$mj_tmp/empty.txt" "$mj_tmp")"

rm -rf "$mj_tmp"

# --- dsh_memo_policy: a malformed threshold falls back to its default, never a silent string compare
mpv_tmp=$(mktemp -d)
mkdir -p "$mpv_tmp/.dsh/policy"
printf 'min_ratio\tgarbage\n' > "$mpv_tmp/.dsh/policy/memorisation.tsv"
is "dsh_memo_policy: a malformed min_ratio falls back to its default" 0.5 \
  "$(dsh_memo_policy min_ratio "$mpv_tmp")"
printf '%s\n' k1 k2 k3 k4 k5 k6 k7 k8 k9 k10 > "$mpv_tmp/test.txt"
: > "$mpv_tmp/prod.tsv"
for v in k1 k2 k3 k4 k5 k6 k7 k8 x1 x2 x3 x4 x5 x6 x7 x8; do
  t=0
  case "$v" in k1) t=1 ;; esac
  printf 'core/src/T.scala\tval:t:2\tstring\t%s\t%s\n' "$v" "$t" >> "$mpv_tmp/prod.tsv"
done
has "dsh_memo_judge: a malformed min_ratio does not silently disable the check (k=8, n=16 still flagged)" \
  "val:t:2	8	16" "$(dsh_memo_judge "$mpv_tmp/prod.tsv" "$mpv_tmp/test.txt" "$mpv_tmp")"

printf 'min_overlap\tlots\n' > "$mpv_tmp/.dsh/policy/memorisation.tsv"
is "dsh_memo_policy: a malformed min_overlap falls back to its default" 8 \
  "$(dsh_memo_policy min_overlap "$mpv_tmp")"

printf 'min_ratio\t0.5\nmin_overlap\t3\n' > "$mpv_tmp/.dsh/policy/memorisation.tsv"
is "dsh_memo_policy: a valid min_ratio is read unaffected" 0.5 \
  "$(dsh_memo_policy min_ratio "$mpv_tmp")"
is "dsh_memo_policy: a valid min_overlap is read unaffected" 3 \
  "$(dsh_memo_policy min_overlap "$mpv_tmp")"
rm -rf "$mpv_tmp"

# --- memorisation.tsv saved from a CRLF editor: tolerated, never silently defaulted ---------------
# Every value of a CRLF table ends in `\r`, which fails the well-formed-decimal test, so a human's real
# override (min_overlap 12) used to be replaced by the default without a word. The `\r` and the blanks
# around a field are stripped BEFORE the value is validated.
mcr_tmp=$(mktemp -d)
mkdir -p "$mcr_tmp/.dsh/policy"
printf '# thresholds\r\nmin_overlap\t12\r\nmin_ratio\t 0.7 \r\ncore/src/T.scala\tval:table:3\tthe note names\r\n' \
  > "$mcr_tmp/.dsh/policy/memorisation.tsv"
is "dsh_memo_policy: a CRLF min_overlap row reads as its value, not the default" 12 \
  "$(dsh_memo_policy min_overlap "$mcr_tmp")"
is "dsh_memo_policy: blanks around a CRLF value are stripped too" 0.7 \
  "$(dsh_memo_policy min_ratio "$mcr_tmp")"
is "dsh_memo_policy: a key the CRLF table does not set keeps its default" 10 \
  "$(dsh_memo_policy trivial_abs "$mcr_tmp")"
is "dsh_memo_allowed: a CRLF allow row still matches its path and construct, and its reason carries no CR" \
  "the note names" "$(dsh_memo_allowed core/src/T.scala val:table:3 "$mcr_tmp")"
rm -rf "$mcr_tmp"

# --- dsh_bounded_probe: a probe bounded without `timeout` -----------------------------------------
bp_tmp=$(mktemp -d)
dsh_bounded_probe 5 "$bp_tmp/out" "$bp_tmp/err" sh -c 'printf "answer\n"; printf "why\n" >&2; exit 3'
is "dsh_bounded_probe: a command that finishes returns 0, whatever its own status" 0 "$?"
is "dsh_bounded_probe: stdout lands in <out>" answer "$(cat "$bp_tmp/out")"
is "dsh_bounded_probe: stderr lands in <err>" why "$(cat "$bp_tmp/err")"
bp_t0=$(date +%s)
dsh_bounded_probe 1 "$bp_tmp/out" "$bp_tmp/err" sleep 30
is "dsh_bounded_probe: a command still running at the bound is killed and answers 124" 124 "$?"
bp_dt=$(( $(date +%s) - bp_t0 ))
if [ "$bp_dt" -lt 10 ]; then ok "dsh_bounded_probe: the kill is prompt (${bp_dt}s for a 1 s bound)"; else bad "dsh_bounded_probe: took ${bp_dt}s for a 1 s bound"; fi
rm -rf "$bp_tmp"

# --- dsh_verify_checks: the memorisation table and the literal_tokens probe ------------------------
vm_tmp=$(mktemp -d)
mkdir -p "$vm_tmp/.dsh/policy" "$vm_tmp/bin"
vm_tsv="$vm_tmp/.dsh/policy/memorisation.tsv"
vm_rows() { SCALASEMANTIC_MCP_LAUNCHER="$vm_tmp/bin/none" dsh_verify_checks "$vm_tmp" 2>&1; }
vm_no() { # vm_no <name> <needle> <haystack>
  case "$3" in *"$2"*) bad "$1: [$2] found in [$3]" ;; *) ok "$1" ;; esac
}

# no table at all: the defaults are in force and nothing is exempt -- a note, not a FAIL
vm_out=$(vm_rows)
has "dsh_verify_checks: no memorisation.tsv is a note naming the defaults" \
  "note	no .dsh/policy/memorisation.tsv" "$vm_out"
# ... and it must still be frozen: an agent could otherwise CREATE it with an exemption for itself
has "dsh_verify_checks: an unfrozen memorisation.tsv is a FAIL even while the file is absent" \
  "FAIL	not frozen (add to .dsh/frozen-paths): .dsh/policy/memorisation.tsv" "$vm_out"

printf '.dsh/policy/memorisation.tsv\tthe human'"'"'s\n' > "$vm_tmp/.dsh/frozen-paths"
printf '# header\n\nmin_overlap\t8\nmin_ratio\t0.5\ntrivial_abs\t10\ncore/src/T.scala\tval:table:3\tthe MIDI note names\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: a well-formed memorisation.tsv parses" \
  "ok	.dsh/policy/memorisation.tsv parses (3 threshold row(s), 1 exemption row(s))" "$vm_out"
has "dsh_verify_checks: a frozen memorisation.tsv is ok" \
  "ok	.dsh/policy/memorisation.tsv is frozen" "$vm_out"
vm_no "dsh_verify_checks: a well-formed, frozen table raises no memorisation FAIL" "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"

printf 'min_overlapp\t3\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: an unknown threshold key is a FAIL" "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"
has "dsh_verify_checks: the FAIL names the row with the unknown key" "line 1: min_overlapp <TAB> 3" "$vm_out"

printf '# c\nmin_ratio\tlots\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: a malformed threshold value is a FAIL, not a silent default" \
  "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"
has "dsh_verify_checks: the FAIL names the malformed row" "line 2: min_ratio <TAB> lots" "$vm_out"

printf 'min_ratio\t0.5.1\n' > "$vm_tsv"
has "dsh_verify_checks: two decimal points are malformed" "line 1: min_ratio <TAB> 0.5.1" "$(vm_rows)"
printf 'min_overlap\t-3\n' > "$vm_tsv"
has "dsh_verify_checks: a negative threshold is malformed" "line 1: min_overlap <TAB> -3" "$(vm_rows)"

printf 'a\tb\tc\td\n' > "$vm_tsv"
has "dsh_verify_checks: a four-field row is a FAIL" "line 1: a <TAB> b <TAB> c <TAB> d" "$(vm_rows)"
printf 'min_overlap 8\n' > "$vm_tsv"
has "dsh_verify_checks: a one-field row (a space, not a TAB) is a FAIL" "line 1: min_overlap 8" "$(vm_rows)"
printf 'core/src/T.scala\tval:t:1\t  \n' > "$vm_tsv"
has "dsh_verify_checks: an exemption with no reason is a FAIL (it would never exempt anything)" \
  "line 1: core/src/T.scala <TAB> val:t:1" "$(vm_rows)"

# A threshold row with a reason column has three fields, so it would read as an exemption for a PATH
# named `min_overlap` -- the check reported `ok ... 1 exemption row(s)` while dsh_memo_policy used the
# default. A threshold key in the first field of a three-field row is a FAIL that says so.
printf 'min_overlap\t12\tthe tests are large\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: a threshold row with a reason column is a FAIL" "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"
has "dsh_verify_checks: the FAIL names the three-field threshold row" "line 1: min_overlap <TAB> 12 <TAB> the tests are large" "$vm_out"
has "dsh_verify_checks: the FAIL says a threshold row takes exactly two fields" "a threshold row takes exactly two fields" "$vm_out"
vm_no "dsh_verify_checks: a three-field threshold row is never counted as an exemption" "1 exemption row(s)" "$vm_out"

# min_ratio above 1 can never be met (k/n <= 1), so it silently switches the check off.
printf 'min_ratio\t5\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: min_ratio above 1 is a FAIL" "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"
has "dsh_verify_checks: the FAIL names the min_ratio row" "line 1: min_ratio <TAB> 5" "$vm_out"
has "dsh_verify_checks: the FAIL says it would disable the check and points at an allow row" \
  "min_ratio above 1 would disable the check" "$vm_out"
has "dsh_verify_checks: ... and names the allow row as the way to exempt" "allow row" "$vm_out"
printf 'min_ratio\t1\n' > "$vm_tsv"
has "dsh_verify_checks: min_ratio exactly 1 is still well-formed" \
  "ok	.dsh/policy/memorisation.tsv parses (1 threshold row(s), 0 exemption row(s))" "$(vm_rows)"
printf 'min_ratio\t1.0001\n' > "$vm_tsv"
has "dsh_verify_checks: min_ratio just above 1 is a FAIL" "line 1: min_ratio <TAB> 1.0001" "$(vm_rows)"

# CRLF: tolerated (the readers strip the CR), but worth knowing -- a note, never a FAIL on its own
printf 'min_overlap\t12\r\ncore/src/T.scala\tval:table:3\tthe note names\r\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: a CRLF table is a note" "note	.dsh/policy/memorisation.tsv has CRLF line endings" "$vm_out"
has "dsh_verify_checks: a CRLF table still parses" \
  "ok	.dsh/policy/memorisation.tsv parses (1 threshold row(s), 1 exemption row(s))" "$vm_out"
vm_no "dsh_verify_checks: a CRLF table alone is no FAIL" "FAIL	.dsh/policy/memorisation.tsv" "$vm_out"
printf 'min_overlap\tlots\r\n' > "$vm_tsv"
vm_out=$(vm_rows)
has "dsh_verify_checks: a malformed CRLF threshold is still a FAIL" "line 1: min_overlap <TAB> lots" "$vm_out"
vm_no "dsh_verify_checks: the named row carries no CR" "$(printf 'lots\r')" "$vm_out"

# the launcher's literal_tokens probe: a one-file `source` request, answered with its literal
vm_l="$vm_tmp/bin/scalasemantic-mcp"
vm_launch() { SCALASEMANTIC_MCP_LAUNCHER="$vm_l" dsh_verify_checks "$vm_tmp" 2>&1; }
cat > "$vm_l" <<'STUB'
#!/bin/sh
printf 'WARNING: A terminally deprecated method in sun.misc.Unsafe has been called\n' >&2
case "$2" in
  literal_tokens)
    case "$3" in
      *'"source"'*) v=$(printf '%s' "$3" | sed 's/.*\\"\([^\\]*\)\\".*/\1/')
        printf '{"files":[{"uri":"DshProbe.scala","literals":[{"line":0,"character":1,"kind":"string","value":"%s","enclosing":null}],"omitted":0,"error":null}]}\n' "$v" ;;
      *) printf '{"files":[{"uri":"x","literals":[],"omitted":0,"error":"no such file"}]}\n' ;;
    esac ;;
  *) printf '{"files":[]}\n' ;;
esac
STUB
chmod +x "$vm_l"
vm_out=$(vm_launch)
has "dsh_verify_checks: a launcher answering literal_tokens with the probe's literal is ok" \
  "ok	the launcher answers \`call literal_tokens\`" "$vm_out"

# a launcher that has `call` but not literal_tokens: `unknown tool` on stderr, nothing on stdout
cat > "$vm_l" <<'STUB'
#!/bin/sh
case "$2" in
  literal_tokens) printf 'unknown tool: literal_tokens (have: resolve_references)\n' >&2 ;;
  *) printf '{"files":[]}\n' ;;
esac
STUB
chmod +x "$vm_l"
vm_out=$(vm_launch)
has "dsh_verify_checks: a launcher without literal_tokens is a note" \
  "note	the launcher at $vm_l does not answer \`call literal_tokens\`" "$vm_out"
vm_no "dsh_verify_checks: a launcher without literal_tokens is never ok for it" \
  "ok	the launcher answers \`call literal_tokens\`" "$vm_out"

# an answer that is JSON but not the probe's literal (a stale, echoing or wrong tool) is not ok either
cat > "$vm_l" <<'STUB'
#!/bin/sh
printf '{"files":[]}\n'
STUB
chmod +x "$vm_l"
vm_out=$(vm_launch)
has "dsh_verify_checks: an answer without the probe's literal is a note" \
  "does not answer \`call literal_tokens\`" "$vm_out"

# a stale launcher (no `call` at all) prints nothing -- a note for literal_tokens too
printf '#!/bin/sh\nexit 0\n' > "$vm_l"
chmod +x "$vm_l"
has "dsh_verify_checks: a stale launcher is a note for literal_tokens" \
  "does not answer \`call literal_tokens\`" "$(vm_launch)"

# no launcher: the resolve_references note already says so; literal_tokens is not probed silently-ok
vm_out=$(vm_rows)
vm_no "dsh_verify_checks: with no launcher, literal_tokens is never reported ok" \
  "ok	the launcher answers \`call literal_tokens\`" "$vm_out"
rm -rf "$vm_tmp"

# this repository's own table parses and is frozen
vm_self=$(dsh_verify_checks "$self_root" 2>&1)
has "dsh_verify_checks: this repository's memorisation.tsv parses" "ok	.dsh/policy/memorisation.tsv parses" "$vm_self"
has "dsh_verify_checks: this repository's memorisation.tsv is frozen" "ok	.dsh/policy/memorisation.tsv is frozen" "$vm_self"
rm -rf "$self_root"

# --- dsh_semantic_launcher: the launcher resolution ---------------------------------------------------
_sl_env_test=$(SCALASEMANTIC_MCP_LAUNCHER=/test/launcher dsh_semantic_launcher)
is "dsh_semantic_launcher: SCALASEMANTIC_MCP_LAUNCHER wins" "/test/launcher" "$_sl_env_test"

# --- dsh_kernels_rows and dsh_kernel_of: kernel registry parsing ------------------------------------
kk_tmp=$(mktemp -d)
mkdir -p "$kk_tmp/.dsh/policy"
# Test parsing: comments, blanks, CR stripping
printf '# header\n\ncore/src/K.scala\tcore\tpilot\r\nsong/src/S.scala\tsong\tx\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(dsh_kernels_rows "$kk_tmp")
has "dsh_kernels_rows: parses rows and skips comments/blanks" "core/src/K.scala" "$kk_rows"
has "dsh_kernels_rows: extracts only file and module (columns 1 and 2)" "core/src/K.scala	core" "$kk_rows"
has "dsh_kernels_rows: strips CR from rows" "song/src/S.scala" "$kk_rows"
case "$kk_rows" in *'pilotpilot'*) bad "dsh_kernels_rows: treats CR as part of line" ;; *) ok "dsh_kernels_rows: CR handled correctly" ;; esac

# Test kernel_of lookup
is "dsh_kernel_of: registered path returns its module" "core" \
  "$(dsh_kernel_of "$kk_tmp" "core/src/K.scala" 2>&1)"
is "dsh_kernel_of: registered path looks up correctly" "song" \
  "$(dsh_kernel_of "$kk_tmp" "song/src/S.scala" 2>&1)"
is "dsh_kernel_of: unregistered path exits 1" "" \
  "$(dsh_kernel_of "$kk_tmp" "other/src/X.scala" 2>&1; [ $? -eq 1 ] && echo)"

# --- dsh_kernel_checks: validation of the kernels registry -------------------------------------------
# absent file: note (early return)
rm -f "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: absent file is a note" "note" "$kk_rows"
has "dsh_kernel_checks: absent file names it" "no .dsh/policy/kernels.tsv" "$kk_rows"
is "dsh_kernel_checks: absent file returns 0" "0" "$(dsh_kernel_checks "$kk_tmp" >/dev/null 2>&1; echo $?)"

# 2-field row: FAIL with line number (line 2: blank, line 3: bad row)
mkdir -p "$kk_tmp/.dsh/.state"
printf '# header\n\ncore/src/K.scala\tcore\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
touch "$kk_tmp/core/src/K.scala"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: 2-field row is a FAIL" "FAIL" "$kk_rows"
has "dsh_kernel_checks: 2-field row names the line number" "kernels.tsv:3" "$kk_rows"
has "dsh_kernel_checks: 2-field row says it needs a reason" "needs <file> TAB <module> TAB <reason>" "$kk_rows"

# missing file: FAIL with line number
printf '# header\ncore/src/K.scala\tcore\treason\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
rm -f "$kk_tmp/core/src/K.scala"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: missing file is a FAIL" "FAIL" "$kk_rows"
has "dsh_kernel_checks: missing file names the line number" "kernels.tsv:2" "$kk_rows"
has "dsh_kernel_checks: missing file names it" "does not exist" "$kk_rows"

# module not in map: FAIL with line number
mkdir -p "$kk_tmp/core/src"
touch "$kk_tmp/core/src/K.scala"
printf 'core/src\tcore\tfmt\n' > "$kk_tmp/.dsh/.state/modules.tsv"
printf '# header\ncore/src/K.scala\tunknown\treason\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: unknown module is a FAIL" "FAIL" "$kk_rows"
has "dsh_kernel_checks: unknown module names the line number" "kernels.tsv:2" "$kk_rows"
has "dsh_kernel_checks: unknown module says it is not in the map" "not in the module map" "$kk_rows"

# not frozen: FAIL
printf 'core/src/K.scala\tcore\treason\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: unfrozen kernels.tsv is a FAIL" "FAIL" "$kk_rows"
has "dsh_kernel_checks: unfrozen kernels.tsv says to freeze it" "not frozen (add to .dsh/frozen-paths)" "$kk_rows"

# Final review F4: a re-vendored project keeps its old frozen-paths (install.sh never overwrites it), so
# the snapshot directory may be unfrozen -- with kernel rows that is a FAIL.
printf '.dsh/policy/kernels.tsv\tthe registry is human-owned\n' > "$kk_tmp/.dsh/frozen-paths"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: unfrozen contract snapshots are a FAIL" \
  "FAIL	the contract snapshots (.dsh/.state/contracts/**) are not frozen — add the row to .dsh/frozen-paths" "$kk_rows"
is "dsh_kernel_checks: unfrozen contract snapshots exit 1" 1 "$(dsh_kernel_checks "$kk_tmp" >/dev/null 2>&1; echo $?)"
: > "$kk_tmp/kk-empty.tsv"; mv "$kk_tmp/.dsh/policy/kernels.tsv" "$kk_tmp/kk-rows.tsv"; cp "$kk_tmp/kk-empty.tsv" "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
case "$kk_rows" in *'contract snapshots'*) bad "dsh_kernel_checks: no kernel rows must not require the snapshot freeze: $kk_rows" ;; *) ok "dsh_kernel_checks: no kernel rows, no snapshot-freeze rule" ;; esac
mv "$kk_tmp/kk-rows.tsv" "$kk_tmp/.dsh/policy/kernels.tsv"

# well-formed without launcher probe: ok
printf '.dsh/policy/kernels.tsv\tthe registry is human-owned\n.dsh/.state/contracts/**\tthe snapshots are the human'"'"'s\n' > "$kk_tmp/.dsh/frozen-paths"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
case "$kk_rows" in *FAIL*) bad "dsh_kernel_checks: kernels.tsv and the snapshots frozen must not FAIL: $kk_rows" ;; *) ok "dsh_kernel_checks: kernels.tsv and the snapshots frozen, no FAIL" ;; esac

# Final review F3: the Stainless wiring files, when they exist, must be frozen too -- an agent that may
# edit them can turn Stainless off (a script that always prints OK).
mkdir -p "$kk_tmp/scripts" "$kk_tmp/buildKit"
printf '#!/bin/sh\n' > "$kk_tmp/scripts/stainless-verify.sh"
printf '// wiring\n' > "$kk_tmp/buildKit/Stainless.mill"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: an unfrozen scripts/stainless-verify.sh is a FAIL" \
  "FAIL	scripts/stainless-verify.sh is not frozen — an agent could disable Stainless; add it to .dsh/frozen-paths" "$kk_rows"
has "dsh_kernel_checks: an unfrozen buildKit/Stainless.mill is a FAIL" \
  "FAIL	buildKit/Stainless.mill is not frozen — an agent could disable Stainless; add it to .dsh/frozen-paths" "$kk_rows"
printf 'scripts/stainless-verify.sh\tthe Stainless wiring is the human'"'"'s\nbuildKit/Stainless.mill\tthe Stainless wiring is the human'"'"'s\n' >> "$kk_tmp/.dsh/frozen-paths"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
case "$kk_rows" in *FAIL*) bad "dsh_kernel_checks: frozen Stainless wiring must not FAIL: $kk_rows" ;; *) ok "dsh_kernel_checks: frozen Stainless wiring passes" ;; esac
rm -rf "$kk_tmp/scripts" "$kk_tmp/buildKit"
kk_rows=$(dsh_kernel_checks "$kk_tmp" 2>&1)
case "$kk_rows" in *stainless-verify*|*Stainless.mill*) bad "dsh_kernel_checks: absent wiring files are not checked: $kk_rows" ;; *) ok "dsh_kernel_checks: absent wiring files are not checked" ;; esac
has "dsh_kernel_checks: well-formed and frozen is ok" "ok" "$kk_rows"
has "dsh_kernel_checks: well-formed reports the count" "1 kernel file(s) registered" "$kk_rows"

# contract_clauses probe: launcher answers good JSON → ok
kk_l="$kk_tmp/bin/scalasemantic-mcp"
mkdir -p "$kk_tmp/bin"
printf '#!/bin/sh\nprintf '\''{"files":[]}'\''\n' > "$kk_l"
chmod +x "$kk_l"
kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: launcher answering contract_clauses is ok" \
  "ok	the launcher answers \`call contract_clauses\`" "$kk_rows"

# contract_clauses probe: launcher prints nothing → note
printf '#!/bin/sh\nexit 0\n' > "$kk_l"
chmod +x "$kk_l"
kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: launcher not answering contract_clauses is a note" \
  "note" "$kk_rows"
has "dsh_kernel_checks: launcher note names reinstall remedy" "reinstall scalasemantic-mcp" "$kk_rows"

# contract_clauses probe: no kernel rows → no probe
rm -f "$kk_tmp/.dsh/policy/kernels.tsv"
touch "$kk_tmp/.dsh/policy/kernels.tsv"
kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: no rows means no launcher probe" "" \
  "$(printf '%s\n' "$kk_rows" | grep -c 'call contract_clauses')"

# modules.tsv absent: note
rm -f "$kk_tmp/.dsh/.state/modules.tsv"
mkdir -p "$kk_tmp/core/src"
touch "$kk_tmp/core/src/K.scala"
printf 'core/src/K.scala\tcore\treason\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
printf '#!/bin/sh\nprintf '\''{"files":[]}'\''\n' > "$kk_l"
chmod +x "$kk_l"
kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
has "dsh_kernel_checks: absent modules.tsv is a note" "note" "$kk_rows"
has "dsh_kernel_checks: absent modules.tsv names it" "modules.tsv is absent" "$kk_rows"
has "dsh_kernel_checks: absent modules.tsv does not block well-formed" "ok" "$kk_rows"

# Path spelling (fix round 1): `./` is normalised, anything else not root-relative FAILs -- a row that
# can never equal a touched path would silently disable the vericoding stage.
printf './core/src/K.scala\tcore\treason\n' > "$kk_tmp/.dsh/policy/kernels.tsv"
is "dsh_kernels_rows: a leading ./ is stripped" "core/src/K.scala	core" "$(dsh_kernels_rows "$kk_tmp")"
is "dsh_kernel_of: a ./-spelled row answers for the plain path" core "$(dsh_kernel_of "$kk_tmp" core/src/K.scala)"
kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
case "$kk_rows" in *FAIL*) bad "dsh_kernel_checks: a ./-spelled existing kernel must not FAIL: $kk_rows" ;; *) ok "dsh_kernel_checks: a ./-spelled existing kernel is accepted" ;; esac
for kk_bad in "$kk_tmp/core/src/K.scala" 'core/../core/src/K.scala' '././core/src/K.scala'; do
  printf '%s\tcore\treason\n' "$kk_bad" > "$kk_tmp/.dsh/policy/kernels.tsv"
  kk_rows=$(SCALASEMANTIC_MCP_LAUNCHER="$kk_l" dsh_kernel_checks "$kk_tmp" 2>&1)
  has "dsh_kernel_checks: $kk_bad is a FAIL naming the rule" \
    "FAIL	.dsh/policy/kernels.tsv:1 $kk_bad must be a root-relative path like core/src/K.scala" "$kk_rows"
done

rm -rf "$kk_tmp"

# --- dsh_is_test_path: a VISIBLE test source -- under its owning module's test/, not sealed -----
itp_tmp=$(mktemp -d)
mkdir -p "$itp_tmp/.dsh/.state"
printf 'core\tcore\tfmt,scalafix,tests\n' > "$itp_tmp/.dsh/.state/modules.tsv"
is "dsh_is_test_path: a path under the module's test/ is a test path" ok \
  "$(dsh_is_test_path core/test/TSpec.scala "$itp_tmp" && echo ok)"
is "dsh_is_test_path: a path under the module's src/ is not a test path" "" \
  "$(dsh_is_test_path core/src/X.scala "$itp_tmp" && echo ok)"
is "dsh_is_test_path: a path under a module not in the map is not a test path" "" \
  "$(dsh_is_test_path other/test/Y.scala "$itp_tmp" && echo ok)"
printf 'sealed\tcore/test/Holdout.scala\tthe holdout suite\n' > "$itp_tmp/.dsh/frozen-paths"
is "dsh_is_test_path: a sealed test path does not count" "" \
  "$(dsh_is_test_path core/test/Holdout.scala "$itp_tmp" && echo ok)"
is "dsh_is_test_path: a merely frozen (not sealed) test path still counts" ok \
  "$(dsh_is_test_path core/test/TSpec.scala "$itp_tmp" && echo ok)"
rm -rf "$itp_tmp"

# --- dsh_memo_read: a literal_tokens answer read against the files REQUESTED --------------------
# `bare` holds every tool on PATH except the two JSON readers, so each reader is exercised on its own
# (`$mr_jq:$bare`, `$mr_py:$bare`) and the no-reader path is real (`$bare` alone).
bare=$(mktemp -d)
_old_ifs=$IFS; IFS=:
for _pd in $PATH; do
  IFS=$_old_ifs
  [ -d "$_pd" ] || continue
  for _px in "$_pd"/*; do
    _pn=${_px##*/}
    case "$_pn" in jq|python|python3*) continue ;; esac
    [ -f "$_px" ] && [ -x "$_px" ] && [ ! -e "$bare/$_pn" ] && ln -s "$_px" "$bare/$_pn"
  done
done
IFS=$_old_ifs
mr_jq=$(mktemp -d); mr_py=$(mktemp -d)
[ "$have_jq" = 1 ] && ln -s "$jq_bin" "$mr_jq/jq"
[ "$have_py" = 1 ] && ln -s "$python_bin" "$mr_py/python3"
mr_tmp=$(mktemp -d)
printf 'core/src/T.scala\ncore/src/U.scala\ncore/src/V.scala\ncore/src/W.scala\n' > "$mr_tmp/req"
# T answered in full, U with an error, V absent, W with 4 literals past the cap; X was never requested.
cat > "$mr_tmp/answer.json" <<'JSON'
{"files":[
 {"uri":"core/src/T.scala","literals":[{"line":3,"character":4,"kind":"string","value":"k1","enclosing":{"kind":"val","name":"table","line":2}},{"line":4,"character":4,"kind":"int","value":"42","enclosing":null}],"omitted":0,"error":null},
 {"uri":"core/src/U.scala","literals":[],"omitted":0,"error":"core/src/U.scala does not parse as Scala 3"},
 {"uri":"core/src/W.scala","literals":[{"line":1,"character":0,"kind":"string","value":"w","enclosing":null}],"omitted":4,"error":null},
 {"uri":"core/src/X.scala","literals":[{"line":1,"character":0,"kind":"string","value":"x","enclosing":null}],"omitted":0,"error":null}
]}
JSON
printf 'this is not JSON\n' > "$mr_tmp/bad.json"
mr_read() { # <reader PATH> <answer> <prefix> -> "rc=<n>"
  PATH="$1" /bin/sh -c '. "$1/lib.sh"; dsh_memo_read "$2" "$3" "$4"; printf "rc=%s" "$?"' _ "$engine" "$2" "$mr_tmp/req" "$3"
}
for _mr in jq python3; do
  if [ "$_mr" = jq ]; then [ "$have_jq" = 1 ] || continue; _mrp="$mr_jq:$bare"; else [ "$have_py" = 1 ] || continue; _mrp="$mr_py:$bare"; fi
  is "dsh_memo_read ($_mr): a JSON answer reads" rc=0 "$(mr_read "$_mrp" "$mr_tmp/answer.json" "$mr_tmp/$_mr")"
  is "dsh_memo_read ($_mr): rows only for requested files the tool answered without error" \
    "core/src/T.scala	3	string	k1	val:table:2
core/src/T.scala	4	int	42	file
core/src/W.scala	1	string	w	file" "$(sort "$mr_tmp/$_mr.rows")"
  is "dsh_memo_read ($_mr): every requested file not fully read is named with its reason" \
    "core/src/U.scala	core/src/U.scala does not parse as Scala 3
core/src/V.scala	no entry in the answer
core/src/W.scala	only partly read: 4 literal(s) past the tool's per-file cap were omitted" "$(cat "$mr_tmp/$_mr.unread")"
  is "dsh_memo_read ($_mr): an answer that is not JSON is rc 1" rc=1 "$(mr_read "$_mrp" "$mr_tmp/bad.json" "$mr_tmp/$_mr.bad")"
done
is "dsh_memo_read: no jq and no python3 is rc 2" rc=2 "$(mr_read "$bare" "$mr_tmp/answer.json" "$mr_tmp/none")"

# The same no-reader path end to end: verify-diff on memo-table-blocks' change must SAY the
# memorisation check did not run, never pass in silence.
mr_root=$(mktemp -d)
cp -R "$engine/tests/cases/memo-table-blocks/root/." "$mr_root/"
( cd "$mr_root" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
  && /bin/sh "$engine/tests/cases/memo-table-blocks/post_git" ) >/dev/null 2>&1
mr_out=$(cd "$mr_root" && env PATH="$engine/tests/bin:$bare" GATE_ROOT="$mr_root" \
  SCALASEMANTIC_STUB_LITERALS_OUT="$mr_root/literals.json" /bin/sh "$engine/verify-diff.sh" 2>&1)
has "verify-diff with no JSON reader says the memorisation check did not run" \
  "no jq and no python3 to read literal_tokens' answer" "$mr_out"

# --- vericoding: contract_clauses rows, the contract diff, Stainless's output (spec 2026-09-27 §3) ------
# The same seam as dsh_memo_read above: `$mr_jq:$bare` and `$mr_py:$bare` each hold ONE JSON reader,
# `$bare` none.
vk_tmp=$(mktemp -d)
cat > "$vk_tmp/answer.json" <<'JSON'
{"files":[
 {"uri":"core/src/K.scala","defs":[
   {"key":"K.f","line":3,"requires":[{"text":"require(x >= 0)","shape":"s1"},{"text":"require(y\t>\n0)","shape":"s2"}],
    "ensuring":{"text":"r => r > x","shape":"s3"},"decreases":{"text":"x","shape":"s4"}},
   {"key":"K.g","line":9,"requires":[],"ensuring":{"text":"r => r","shape":null},"decreases":null},
   {"key":"K.plain","line":12,"requires":[],"ensuring":null,"decreases":null}],"error":null},
 {"uri":"core/src/Bad.scala","defs":[],"error":"core/src/Bad.scala does not parse"}
]}
JSON
vk_want_rows="core/src/K.scala	K.f	requires	0	s1	require(x >= 0)
core/src/K.scala	K.f	requires	1	s2	require(y > 0)
core/src/K.scala	K.f	ensuring	0	s3	r => r > x
core/src/K.scala	K.f	decreases	0	s4	x
core/src/K.scala	K.g	ensuring	0		r => r"
vk_tsv() { # <reader PATH> <answer> -> rows, then "rc=<n>"
  PATH="$1" /bin/sh -c '. "$1/lib.sh"; dsh_contracts_tsv "$2"; printf "rc=%s" "$?"' _ "$engine" "$2"
}
printf 'core/src/K.scala\ncore/src/Bad.scala\ncore/src/Gone.scala\n' > "$vk_tmp/req"
for _vr in jq python3; do
  if [ "$_vr" = jq ]; then [ "$have_jq" = 1 ] || continue; _vrp="$mr_jq:$bare"; else [ "$have_py" = 1 ] || continue; _vrp="$mr_py:$bare"; fi
  is "dsh_contracts_tsv ($_vr): one row per clause, index per requires, tabs/newlines flattened, null shape empty" \
    "$vk_want_rows
rc=0" "$(vk_tsv "$_vrp" "$vk_tmp/answer.json")"
  printf 'not json\n' > "$vk_tmp/bad.json"
  has "dsh_contracts_tsv ($_vr): an answer that is not JSON is rc 1" "rc=1" "$(vk_tsv "$_vrp" "$vk_tmp/bad.json")"
  is "dsh_contracts_unread ($_vr): an errored file and an absent file are named, a clean one is not" \
    "core/src/Bad.scala	core/src/Bad.scala does not parse
core/src/Gone.scala	no entry in the answer
rc=0" "$(PATH="$_vrp" /bin/sh -c '. "$1/lib.sh"; dsh_contracts_unread "$2" "$3"; printf "rc=%s" "$?"' _ "$engine" "$vk_tmp/answer.json" "$vk_tmp/req")"
done
if [ "$have_jq" = 1 ] && [ "$have_py" = 1 ]; then
  is "dsh_contracts_tsv: jq and python3 print identical rows" \
    "$(vk_tsv "$mr_jq:$bare" "$vk_tmp/answer.json")" "$(vk_tsv "$mr_py:$bare" "$vk_tmp/answer.json")"
else
  printf 'note dsh_contracts_tsv cross-reader agreement not compared: only one of jq/python3 is on PATH\n'
fi
is "dsh_contracts_tsv: no jq and no python3 is rc 2" "rc=2" "$(vk_tsv "$bare" "$vk_tmp/answer.json")"
is "dsh_contract_file: under the state dir, keyed by the sanitised session id" \
  "$(state_dir)/contracts/a_b.tsv" "$(dsh_contract_file 'a/b')"

# dsh_contract_diff: changed / removed / added-ignored / uri filter / `#` lines skipped
t=$(printf '\t')
cat > "$vk_tmp/before.tsv" <<ROWS
# DSH contract snapshot s1 2026-09-27T00:00:00Z
# file A.scala
A.scala${t}K.f${t}requires${t}0${t}s1${t}require(x >= 0)
A.scala${t}K.f${t}ensuring${t}0${t}s2${t}r => r > x
A.scala${t}K.g${t}requires${t}0${t}s5${t}require(y > 0)
B.scala${t}L.h${t}ensuring${t}0${t}s9${t}r => true
ROWS
cat > "$vk_tmp/after.tsv" <<ROWS
A.scala${t}K.f${t}requires${t}0${t}s1x${t}require(x >= 1)
A.scala${t}K.f${t}ensuring${t}0${t}s2${t}r  =>  r > x
A.scala${t}K.lemma${t}ensuring${t}0${t}s7${t}_ => true
ROWS
printf 'A.scala\n' > "$vk_tmp/uris"
is "dsh_contract_diff: a changed shape and a removed clause, in snapshot order; same shape passes; new lemma and other uris ignored" \
  "changed	A.scala	K.f	requires	require(x >= 0)	require(x >= 1)
removed	A.scala	K.g	requires	require(y > 0)" "$(dsh_contract_diff "$vk_tmp/before.tsv" "$vk_tmp/after.tsv" "$vk_tmp/uris")"
: > "$vk_tmp/none"
is "dsh_contract_diff: no uris, no rows" "" "$(dsh_contract_diff "$vk_tmp/before.tsv" "$vk_tmp/after.tsv" "$vk_tmp/none")"
printf 'B.scala\n' > "$vk_tmp/uris"
is "dsh_contract_diff: a def with a contract that vanished entirely is removed" \
  "removed	B.scala	L.h	ensuring	r => true" "$(dsh_contract_diff "$vk_tmp/before.tsv" "$vk_tmp/after.tsv" "$vk_tmp/uris")"

# Final review F1: a clause ADDED to a def the snapshot already had a contract for is a change (adding a
# precondition is how a counterexample is made to vanish): a new kind on a seen key, and an appended
# requires index. A def the snapshot never saw (a lemma) stays allowed.
cat > "$vk_tmp/b5.tsv" <<ROWS
# DSH contract snapshot s1 2026-09-27T00:00:00Z
# file A.scala
A.scala${t}K.f${t}ensuring${t}0${t}s2${t}r => r > x
A.scala${t}K.h${t}requires${t}0${t}s5${t}require(y > 0)
ROWS
cat > "$vk_tmp/a5.tsv" <<ROWS
A.scala${t}K.f${t}requires${t}0${t}s1${t}require(x > 0)
A.scala${t}K.f${t}ensuring${t}0${t}s2${t}r => r > x
A.scala${t}K.h${t}requires${t}0${t}s5${t}require(y > 0)
A.scala${t}K.h${t}requires${t}1${t}s6${t}require(z > 0)
A.scala${t}K.lemma${t}requires${t}0${t}s7${t}require(w > 0)
A.scala${t}K.lemma${t}ensuring${t}0${t}s8${t}_ => true
ROWS
printf 'A.scala\n' > "$vk_tmp/uris"
is "dsh_contract_diff: a new clause kind on a snapshotted def, and an appended requires, are added; a new def is not" \
  "added	A.scala	K.f	requires	require(x > 0)
added	A.scala	K.h	requires	require(z > 0)" "$(dsh_contract_diff "$vk_tmp/b5.tsv" "$vk_tmp/a5.tsv" "$vk_tmp/uris")"
printf 'B.scala\n' > "$vk_tmp/uris"
is "dsh_contract_diff: an added clause in a uri not asked about is not reported" "" \
  "$(dsh_contract_diff "$vk_tmp/b5.tsv" "$vk_tmp/a5.tsv" "$vk_tmp/uris")"

# Final review extra: a budget knob with leading zeros is a decimal number, never an octal one (`$((08))`
# is an arithmetic error that crashes the hook under dash and bash alike); junk falls back to the default.
is "dsh_decimal: leading zeros stripped" 90 "$(dsh_decimal 0090 540)"
is "dsh_decimal: 08 is eight, not an octal error" 8 "$(dsh_decimal 08 540)"
is "dsh_decimal: a lone 0 stays 0" 0 "$(dsh_decimal 0 540)"
is "dsh_decimal: all zeros is 0" 0 "$(dsh_decimal 000 540)"
is "dsh_decimal: a plain number is itself" 480 "$(dsh_decimal 480 540)"
is "dsh_decimal: empty is the default" 540 "$(dsh_decimal '' 540)"
is "dsh_decimal: junk is the default" 540 "$(dsh_decimal 5x 540)"
is "dsh_decimal: a negative is the default" 540 "$(dsh_decimal -5 540)"
# DSH_TESTS_CAP (spec 2026-09-28 §3, the turnEndTests time cap): the same dsh_decimal rule, its own
# default (300) instead of the Stop-hook budget's 540.
is "dsh_decimal: DSH_TESTS_CAP junk falls back to its own default (300)" 300 "$(dsh_decimal bad 300)"
is "dsh_decimal: DSH_TESTS_CAP leading zeros stripped like every other knob" 2 "$(dsh_decimal 002 300)"

# Final review F3: the verification escapes a kernel carries -- non-comment lines naming assume(, @extern
# or @ignore (a line whose first non-blank characters are `//` or `*` is a comment).
cat > "$vk_tmp/Esc.scala" <<'SCALA'
object K {
  // assume(x > 0) is only a comment
   * @extern in a doc comment
  @extern def ext(x: BigInt): BigInt = x
  def f(x: BigInt): BigInt = {
    assume(x > 0); assume(x > 1)
    x
  }
  @ignore def g = 1
  val assumed = 1
  /* assume(x) */
}
SCALA
is "dsh_escape_count: assume(, @extern and @ignore lines, comments skipped, one per line" 4 "$(dsh_escape_count "$vk_tmp/Esc.scala")"
is "dsh_escape_lines: each counted line as <n>: <text>" \
"4:  @extern def ext(x: BigInt): BigInt = x
6:    assume(x > 0); assume(x > 1)
9:  @ignore def g = 1
11:  /* assume(x) */" "$(dsh_escape_lines "$vk_tmp/Esc.scala")"
printf 'object K { val x = 1 }\n' > "$vk_tmp/Clean.scala"
is "dsh_escape_count: a clean file is 0" 0 "$(dsh_escape_count "$vk_tmp/Clean.scala")"
is "dsh_escape_count: a missing file is 0" 0 "$(dsh_escape_count "$vk_tmp/Nope.scala")"
t=$(printf '\t')
printf '# DSH contract snapshot s1 d\n# file a b/K.scala\n# escapes a b/K.scala 2\n# escapes core/L.scala 0\n' > "$vk_tmp/esnap.tsv"
is "dsh_snapshot_escapes: the recorded count for a uri (a space in the path is kept)" 2 "$(dsh_snapshot_escapes "$vk_tmp/esnap.tsv" 'a b/K.scala')"
is "dsh_snapshot_escapes: a zero count" 0 "$(dsh_snapshot_escapes "$vk_tmp/esnap.tsv" core/L.scala)"
is "dsh_snapshot_escapes: no line for the uri is empty, exit 1" "rc=1" "$(dsh_snapshot_escapes "$vk_tmp/esnap.tsv" other/M.scala; printf 'rc=%s' "$?")"

# dsh_stainless_report / _verdict / _unknowns over Task 1's real captures
fx="$engine/tests/fixtures/stainless"
esc=$(printf '\033')
max_lines=15
vk_r=$(dsh_stainless_report "$fx/invalid.txt")
is "dsh_stainless_report invalid.txt: the VC, its counterexample, the unknown count" \
  "INVALID core/src/Invalid.scala:3:22: 'postcondition' VC for inc
  counterexample:
    x: BigInt -> BigInt(\"0\")
unknown 0" "$vk_r"
case "$vk_r" in *"$esc"*) bad "dsh_stainless_report: ANSI escape survived" ;; *) ok "dsh_stainless_report: colour stripped" ;; esac
is "dsh_stainless_report unknown.txt: no invalid VC, unknown 1" "unknown 1" "$(dsh_stainless_report "$fx/unknown.txt")"
is "dsh_stainless_report valid.txt: unknown 0 only" "unknown 0" "$(dsh_stainless_report "$fx/valid.txt")"
# A long counterexample: 40 bindings, one of them 1000 characters -> bounded lines, each line cut.
{
  cat "$fx/invalid.txt"
  printf '[Warning ]  - Result for '"'"'postcondition'"'"' VC for big @9:1:\n'
  printf '[Warning ] core/src/Big.scala:9:1:  => INVALID\n'
  printf '[Warning ] Found counter-example:\n'
  i=0; while [ "$i" -lt 40 ]; do printf '[Warning ]   v%s: BigInt -> BigInt("%s")\n' "$i" "$i"; i=$((i + 1)); done
  printf '[Warning ]   long: List[BigInt] -> %s\n' "$(awk 'BEGIN { for (i = 0; i < 1000; i++) printf "9" }')"
} > "$vk_tmp/long.txt"
vk_r=$(dsh_stainless_report "$vk_tmp/long.txt")
is "dsh_stainless_report: bounded to max_lines (13 kept + the cut marker + unknown)" 15 "$(printf '%s\n' "$vk_r" | wc -l | tr -d ' ')"
has "dsh_stainless_report: the cut is said" "more lines" "$vk_r"
max_lines=60
vk_r=$(dsh_stainless_report "$vk_tmp/long.txt")
is "dsh_stainless_report: no line longer than 240 characters + the marker" "" \
  "$(printf '%s\n' "$vk_r" | awk 'length($0) > 245')"
max_lines=15
is "dsh_stainless_verdict invalid.txt (Mill exit 1)" "invalid	" "$(dsh_stainless_verdict "$fx/invalid.txt" 1)"
is "dsh_stainless_verdict valid.txt" "ok	" "$(dsh_stainless_verdict "$fx/valid.txt" 0)"
is "dsh_stainless_verdict unknown.txt: the script passes unknowns" "ok	" "$(dsh_stainless_verdict "$fx/unknown.txt" 0)"
sed 's/cache, nativez3, non-batched/missing implementations, cache, choose injection,/' "$fx/valid.txt" > "$vk_tmp/missing.txt"
is "dsh_stainless_verdict: OK with a missing-implementations pipeline marker is missing, never ok" \
  "missing	" "$(dsh_stainless_verdict "$vk_tmp/missing.txt" 0)"
is "dsh_stainless_verdict: OK marker but Mill failed is setup" \
  "setup	Mill exited 1 after scripts/stainless-verify.sh reported OK" "$(dsh_stainless_verdict "$fx/valid.txt" 1)"
printf 'stainless-verify: SETUP — no Stainless summary in the output (tool or compile error above)\n[error] core.stainlessVerify\n' > "$vk_tmp/setup.txt"
is "dsh_stainless_verdict: the SETUP marker's reason" \
  "setup	no Stainless summary in the output (tool or compile error above)" "$(dsh_stainless_verdict "$vk_tmp/setup.txt" 1)"
printf 'usage: stainless-verify.sh <file.scala> [<file.scala> ...]\n' > "$vk_tmp/usage.txt"
has "dsh_stainless_verdict: the usage line is setup" "setup	the verify script was run without a target" "$(dsh_stainless_verdict "$vk_tmp/usage.txt" 1)"
printf 'Cannot resolve core.stainlessVerify. Try `mill resolve core._` to see what is available.\n' > "$vk_tmp/nomarker.txt"
is "dsh_stainless_verdict: no marker at all (module without StainlessModule) is setup, naming Mill's line" \
  "setup	no verdict line from scripts/stainless-verify.sh (Mill exit 1): Cannot resolve core.stainlessVerify. Try \`mill resolve core._\` to see what is available." \
  "$(dsh_stainless_verdict "$vk_tmp/nomarker.txt" 1)"
is "dsh_stainless_unknowns unknown.txt: the timed-out VC from the summary table" \
  "probe/Unknown.scala:6:5  samplesToNanos  body assertion: Multiplication overflow  (timeout)" \
  "$(dsh_stainless_unknowns "$fx/unknown.txt")"
is "dsh_stainless_unknowns valid.txt: none" "" "$(dsh_stainless_unknowns "$fx/valid.txt")"

# Fix round 1, item 3: Stainless's own compile/extraction errors naming a TARGET file are `rejected`
# (the body left the supported subset), not a setup failure the agent can walk past.
rj="$engine/tests/cases/vericoding-stainless-rejects-body-blocks/root/stainless.txt"
is "dsh_stainless_verdict: a SETUP run whose [ Error  ] lines name a target is rejected at file:line" \
  "rejected	core/src/K.scala:5" "$(dsh_stainless_verdict "$rj" 1 core/src/K.scala,core/src/L.scala)"
is "dsh_stainless_verdict: the same errors naming no target stay setup" \
  "setup	no Stainless summary in the output (tool or compile error above)" "$(dsh_stainless_verdict "$rj" 1 core/src/Other.scala)"
is "dsh_stainless_verdict: no targets given is the old verdict" \
  "setup	no Stainless summary in the output (tool or compile error above)" "$(dsh_stainless_verdict "$rj" 1)"
is "dsh_stainless_errors: the error lines with their source context, colour-free, the terminal line dropped" \
  "[ Error  ] core/src/K.scala:5:24: Found:    (r : Short)
[ Error  ] Required: Boolean
               (v >= 32767.0  ==> r == 32767) &&
                                  ^" "$(dsh_stainless_errors "$rj")"
is "dsh_stainless_verdict: an absolute spelling of a target also matches" "rejected	core/src/K.scala:5" \
  "$(sed 's|\] core/src/K.scala:|] /repo/core/src/K.scala:|' "$rj" > "$vk_tmp/abs.txt"; dsh_stainless_verdict "$vk_tmp/abs.txt" 1 core/src/K.scala | sed 's|/repo/||')"

# Fix round 1, item 4: an empty shape on either side compares TEXT; empty shape AND text is unreadable.
cat > "$vk_tmp/b4.tsv" <<ROWS
A.scala${t}K.a${t}requires${t}0${t}${t}require(a > 0)
A.scala${t}K.b${t}requires${t}0${t}${t}require(b > 0)
A.scala${t}K.c${t}ensuring${t}0${t}s3${t}r => r > c
A.scala${t}K.d${t}ensuring${t}0${t}${t}
A.scala${t}K.e${t}ensuring${t}0${t}s5${t}r => r > e
ROWS
cat > "$vk_tmp/a4.tsv" <<ROWS
A.scala${t}K.a${t}requires${t}0${t}${t}require(a > 1)
A.scala${t}K.b${t}requires${t}0${t}sb${t}require(b > 0)
A.scala${t}K.c${t}ensuring${t}0${t}${t}r => r >= c
A.scala${t}K.d${t}ensuring${t}0${t}sd${t}r => r
A.scala${t}K.e${t}ensuring${t}0${t}${t}
ROWS
printf 'A.scala\n' > "$vk_tmp/uris"
is "dsh_contract_diff: empty shape -> text compared; empty shape and text -> unreadable" \
  "changed	A.scala	K.a	requires	require(a > 0)	require(a > 1)
changed	A.scala	K.c	ensuring	r => r > c	r => r >= c
unreadable	A.scala	K.d	ensuring
unreadable	A.scala	K.e	ensuring" "$(dsh_contract_diff "$vk_tmp/b4.tsv" "$vk_tmp/a4.tsv" "$vk_tmp/uris")"

rm -rf "$vk_tmp"
rm -rf "$bare" "$mr_jq" "$mr_py" "$mr_tmp" "$mr_root"

# --- the memorisation cache without a hasher: never keyed on content it cannot see --------------
# `dsh_file_hash` prints `-` for every file when neither shasum nor sha256sum is on PATH, so a cache
# keyed on it changes only when the LIST of test files changes. Here a first run caches a test set
# disjoint from the table; the test file is then edited to assert the table's values. A stale cache
# would undercount the overlap and pass in silence: with no hasher the set must be read fresh.
nohash=$(mktemp -d)
_old_ifs=$IFS; IFS=:
for _pd in $PATH; do
  IFS=$_old_ifs
  [ -d "$_pd" ] || continue
  for _px in "$_pd"/*; do
    _pn=${_px##*/}
    case "$_pn" in shasum*|sha256sum*) continue ;; esac
    [ -f "$_px" ] && [ -x "$_px" ] && [ ! -e "$nohash/$_pn" ] && ln -s "$_px" "$nohash/$_pn"
  done
done
IFS=$_old_ifs
nh_root=$(mktemp -d)
cp -R "$engine/tests/cases/memo-table-blocks/root/." "$nh_root/"
( cd "$nh_root" && git init -q . && git add -A && git -c user.email=t@t -c user.name=t commit -qm base \
  && /bin/sh "$engine/tests/cases/memo-table-blocks/post_git" ) >/dev/null 2>&1
sed 's/"value": "k\([0-9]*\)", "enclosing": null/"value": "t\1", "enclosing": null/g' \
  "$nh_root/literals.json" > "$nh_root/literals-disjoint.json"
nh_run() { # <literals answer> -> the verify-diff output, then "rc=<n>"
  (cd "$nh_root" && env PATH="$engine/tests/bin:$nohash" GATE_ROOT="$nh_root" \
    SCALASEMANTIC_STUB_LITERALS_OUT="$1" /bin/sh "$engine/verify-diff.sh" 2>&1; printf 'rc=%s' "$?")
}
is "no hasher: the stripped PATH really has none" "" \
  "$(PATH="$nohash" /bin/sh -c '. "$1/lib.sh"; dsh_has_hasher && echo has' _ "$engine")"
nh_out=$(nh_run "$nh_root/literals-disjoint.json")
has "no hasher: tests disjoint from the table pass" "rc=0" "$nh_out"
printf '  val more = 1\n' >> "$nh_root/core/test/TSpec.scala"
nh_out=$(nh_run "$nh_root/literals.json")
has "no hasher: an edited test's new values are read fresh, not from a stale cache" \
  "10 of 10 literals also appear in the tests" "$nh_out"
is "no hasher: no test-literal cache is written" "" "$(ls "$nh_root/.dsh/.state" | grep memo-testvals)"
rm -rf "$nohash" "$nh_root"

# dsh_fixture_shape_gaps (2026-09-29): sixteen fixtures wrote into directories a clone does not have, and
# only a vendored project's check-harness saw it. The template's own fixtures must have no gap here, and
# the reading must find something to assert (a zero destination count proves nothing).
# "A clone has it" only means something once the fixtures are in git: a just-vendored, uncommitted
# engine tracks nothing yet (install.sh does not stage), and check-harness group D names untracked
# fixture files on its own -- so this row runs where the tree is tracked (the template, a committed
# vendor) and is skipped, by name, where it is not.
fs_out=$(dsh_fixture_shape_gaps "$engine")
if [ -n "$(git -C "$engine" ls-files -- tests/cases 2>/dev/null | head -n 1)" ]; then
  is "fixture shape: the engine's own post_git/mutate_between write only into directories a clone has" "" "$(printf '%s\n' "$fs_out" | sed '1d')"
else
  is "fixture shape: skipped -- this engine's fixtures are not tracked by git yet (commit the vendor)" "" ""
fi
is "fixture shape: destinations were read" yes "$(printf '%s\n' "$fs_out" | sed -n '1p' | awk '$3 > 0 { print "yes" }')"
fs_eng=$(mktemp -d "${TMPDIR:-/tmp}/dsh-fs.XXXXXX")
mkdir -p "$fs_eng/tests/cases/gap" "$fs_eng/tests/cases/made"
printf '#!/bin/sh\nprintf x > a/b.txt\n' > "$fs_eng/tests/cases/gap/post_git"
printf '#!/bin/sh\nmkdir -p a/\nprintf x > a/b.txt\n' > "$fs_eng/tests/cases/made/post_git"
fs_out=$(dsh_fixture_shape_gaps "$fs_eng")
is "fixture shape: a write into a directory nothing makes is a gap" yes "$(printf '%s\n' "$fs_out" | grep -q '^post_git of case gap writes to a/b.txt' && echo yes || echo no)"
is "fixture shape: mkdir -p a/ (trailing slash) makes a/" no "$(printf '%s\n' "$fs_out" | grep -q 'case made' && echo yes || echo no)"
rm -rf "$fs_eng"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
