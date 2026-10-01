#!/bin/sh
# Shared helpers for the DSH gate. Sourced, never executed directly.
# POSIX sh only: no arrays, no `local`, no `set -e` (a hook must not die mid-decision).

# Root resolution order: the test seam, Claude Code's variable, git, then PWD.
gate_root() {
  if [ -n "${GATE_ROOT:-}" ]; then printf '%s\n' "$GATE_ROOT"; return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s\n' "$CLAUDE_PROJECT_DIR"; return; fi
  git rev-parse --show-toplevel 2>/dev/null || printf '%s\n' "$PWD"
}

state_dir() { printf '%s\n' "$(gate_root)/.dsh/.state"; }

# Read one field out of the hook payload by dotted path, e.g. `tool_input.command`.
# Both readers render a value the same way — null as the empty string, strings as
# themselves, booleans as true/false, numbers as their decimal text and containers as
# compact JSON — so a field reads identically whichever reader this host has.
payload_get() {
  _p="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | jq -r --arg p "$_p" 'getpath($p | split(".")) | if . == null then "" elif type == "string" then . else tostring end' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
cur = d
for k in sys.argv[1].split("."):
    cur = cur.get(k, "") if isinstance(cur, dict) else ""
if cur is None:
    print("")
elif isinstance(cur, str):
    print(cur)
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, separators=(",", ":")))
else:
    print(str(cur))' "$_p" 2>/dev/null
  fi
}

# The same payload with tool_name replaced, for delegating to a Claude Code-dialect script.
# Whole-payload output follows the same contract as payload_get: compact JSON.
payload_with_tool() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | jq -c --arg t "$1" '.tool_name = $t' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
d["tool_name"] = sys.argv[1]
json.dump(d, sys.stdout, separators=(",", ":"))' "$1" 2>/dev/null
  fi
}

# Is <dotted path> PRESENT in the payload? `payload_get` renders an absent key and a JSON null as
# the same empty string, which cannot tell "no `write` argument" from "`write` is the empty string"
# -- and for the semantic server's annotated buffer those are two different calls: a read, and a
# truncation. True for any value that is present and not null (an empty string included), false
# otherwise; a host with no JSON reader answers false, which is the same verdict `payload_get`
# reaches for every field there.
payload_has() {
  _ph="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | jq -e --arg p "$_ph" 'getpath($p | split(".")) != null' >/dev/null 2>&1
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
cur = d
for k in sys.argv[1].split("."):
    if not isinstance(cur, dict) or k not in cur:
        sys.exit(1)
    cur = cur[k]
sys.exit(1 if cur is None else 0)' "$_ph" >/dev/null 2>&1
    return $?
  fi
  return 1
}

# 0 when a JSON reader exists and the payload parses as a JSON object; otherwise prints the
# reason on stdout and returns 1. Called once, centrally, so no hook fails open in silence.
gate_payload_verdict() {
  if [ -z "${GATE_PAYLOAD:-}" ]; then
    printf '%s\n' "the hook payload on stdin was empty"
    return 1
  fi
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | jq -e 'type == "object"' >/dev/null 2>&1 || {
      printf '%s\n' "the hook payload is not valid JSON (jq)"
      return 1
    }
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$GATE_PAYLOAD" | python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
sys.exit(0 if isinstance(d, dict) else 1)' >/dev/null 2>&1 || {
      printf '%s\n' "the hook payload is not valid JSON (python3)"
      return 1
    }
    return 0
  fi
  printf '%s\n' "no JSON reader (jq or python3) on PATH"
  return 1
}

# --- the shared output bounds (F59, F62) -----------------------------------------------------
# One implementation for every hook that hands text back to an agent, so the two gates cannot drift
# apart on how much of a failing check's output is worth showing.
#
# `bound_bytes` cuts <text> to at most <max> BYTES, with the marker appended when anything was
# dropped. This is the bound that protects session context, and `cut -c` cannot be it: `-c` cuts per
# LINE, so a report of many long lines stays unbounded (measured: five failing checks x 20 lines of
# 5 KB handed back 300 KB, and lowering the cap to 200 bytes changed nothing). `head -c` counts
# bytes. The 16-byte slack covers the marker's own bytes — bash counts those as characters and dash
# as bytes — plus the space before it.
#
# The marker is a variable, not a literal, so a caller can reword it; its default is the wording both
# gates have always used.
#
# `bound_lines` cuts <text> to its first <max> LINES and says how many it dropped: the per-section
# bound both gates apply before the whole message is byte-bounded.
#
# `2>/dev/null` on both printfs is not decoration — F62, the same defect F59 fixed for bound_bytes:
# with SIGPIPE ignored (the disposition a hook inherits in production) bash 3.2's printf reports
# `write error: Broken pipe` when `head` closes the pipe first, and that line arrives AHEAD of the
# gate's own message, so the reason the agent reads starts with shell noise (measured: 59 bytes of it
# on a 480 KB report, gone with the redirect). `head -n` and `head -c` both close early by design.
bound_marker='… truncated'
# The bytes of an INCOMPLETE UTF-8 sequence at the end of a cut: a 2-byte lead alone, a 3-byte lead with at
# most one continuation byte, a 4-byte lead with at most two (C-locale byte ranges, built with printf).
_bb_c=$(printf '\200-\277')
_bb_partial="([$(printf '\300-\337')]|[$(printf '\340-\357')][$_bb_c]?|[$(printf '\360-\367')][$_bb_c]{0,2})"
bound_bytes() { # <text> <max bytes>
  _b=$(printf '%s' "$1" | wc -c | tr -d ' ')
  if [ "$_b" -le "$2" ]; then
    printf '%s\n' "$1"
  else
    _lim=$(($2 - 16))
    [ "$_lim" -gt 0 ] || _lim=0
    # `head -c` can stop inside a multibyte character; an incomplete sequence at the very end of the cut
    # is dropped (C locale, so sed sees bytes; the `$` address touches the last line only), so the cut
    # stays valid UTF-8 and only gets shorter. Command substitution keeps sed's added newline out.
    _cut=$(printf '%s' "$1" 2>/dev/null | head -c "$_lim" | LC_ALL=C sed -E "\$ s/$_bb_partial\$//")
    printf '%s' "$_cut"
    printf ' %s\n' "$bound_marker"
  fi
}

bound_lines() { # <text> <max lines>
  _n=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  if [ "$_n" -le "$2" ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$1" 2>/dev/null | head -n "$2"
    printf '… %s more lines\n' "$((_n - $2))"
  fi
}

# Does a check's output name a file at all? A token ending in one of <extensions>, so that
# `.scalafmt.conf` — which `checkFormat` prints on every failure, even one naming no source file —
# and `A.scala.semanticdb` are not mistaken for files the diagnostics are about. The extensions are
# an ERE alternation, one per caller's vocabulary (post-edit: source files; turn-end: those plus
# `.mill`, whose build changes are that gate's business too). The printf is silenced for the reason
# in `bound_lines` above: `grep -q` exits at the first match, and the leftover write would otherwise
# be reported on stderr.
names_file() { # <text> <extensions as an ERE alternation>
  printf '%s\n' "$1" 2>/dev/null | grep -Eq -- "[^[:space:]]+\.($2)([^[:alnum:].]|$)"
}

# The first line of <text>, with no pipeline at all. `printf '%s\n' "$1" | head -n 1` is the same
# defect as the two above, and was the fourth instance of it found in this hook family (F63): once the
# text is over the pipe capacity the reader is gone before the writer is done, and the shell's
# `write error: Broken pipe` lands on stderr as the FIRST line of what an agent reads. Parameter
# expansion cannot fail that way, so this removes the failure mode instead of suppressing it.
first_line() { # <text>
  _fl_nl='
'
  printf '%s' "${1%%"$_fl_nl"*}"
}

# --- the shared report plumbing (M3) ---------------------------------------------------------
# The two Mill-running gates (post-edit.sh, turn-end.sh) build their message the same way and had
# these three blocks copied into both files: `section()` byte-identical, `has_cap` the same logic
# twice, and the Mill resolution the same rule with two spellings of the wrapper test. They live here
# for the reason `bound_lines`/`names_file` do: one implementation, so the two gates cannot drift
# apart on a question they both have to answer the same way — and `lib-test.sh` pins each of them.

# section <blocking|note> <title> <body>: append one section to the caller's `report` (blocking) or
# `notes` (not blocking), with the body cut to `max_lines` by `bound_lines`. The three variables
# belong to the caller: both gates set `report`, `notes` and `max_lines` before the first call, and
# POSIX sh has no `local`, so this writes into them by name.
section() {
  _body=$3
  [ -n "$_body" ] || _body='(the check printed nothing)'
  if [ "$1" = blocking ]; then
    report="$report
--- $2 ---
$(bound_lines "$_body" "$max_lines")"
  else
    notes="$notes
--- $2 ---
$(bound_lines "$_body" "$max_lines")"
  fi
}

# Is <capability> one of the comma-separated tokens in the caller's `caps` — a module map row's
# capabilities, e.g. `fmt,scalafix,tests`? Both sides are wrapped in commas so a token can only match
# whole: `fmt` must not be found inside `fixfmt`, and `test` must not be found inside `tests`.
has_cap() {
  case ",${caps}," in
    *",$1,"*) return 0 ;;
  esac
  return 1
}

# resolve_mill <root>: print the Mill to run — the repository's own wrapper `./mill` when <root>/mill
# is an executable file, else a `mill` on PATH — and return 1 when there is neither, so the caller can
# fail closed with its own wording. `./mill` is a relative spelling on purpose: both callers cd to the
# root before running it, and a fixture's scratch root has no wrapper, which is what puts the stub on
# PATH in charge (and keeps every case hermetic).
resolve_mill() {
  if [ -f "$1/mill" ] && [ -x "$1/mill" ]; then
    printf '%s\n' './mill'
    return 0
  fi
  _mill_on_path=$(command -v mill 2>/dev/null) || _mill_on_path=""
  if [ -n "$_mill_on_path" ]; then
    printf '%s\n' "$_mill_on_path"
    return 0
  fi
  return 1
}

# dsh_check_through_wrapper <label> <mill> <task...>: run one Mill check through the feedback wrapper
# (hooks/feedback.sh --selector <label>) and hand back, in three globals the way `section` writes
# `report`/`notes` (POSIX sh has no `local`):
#   DSH_CHECK_RC     the command's exit status (the wrapper propagates it; the gate blocks on THIS)
#   DSH_CHECK_RAW    the raw log the wrapper kept -- attribution (post-edit's `_mine`, turn-end's
#                    `attributable`, both gates' `names_file`) reads this, because it must see every
#                    path Mill printed, including the ones the renderer folded (F53)
#   DSH_CHECK_SHOWN  the text the agent reads: the rendered DIAGNOSTIC/INSTRUCTION block, except
#                    when that block carries an UNREADABLE: or INFRA: line (right under the
#                    FEEDBACK: header) -- then the adapters made nothing of the log and the raw text
#                    is shown instead, bounded by `section` as every section is
# and return DSH_CHECK_RC. Both Mill-running gates decided these three things in twenty identical
# lines each; "which checks go raw" (checkFormat: a file list, not diagnostics -- the caller keeps
# that branch) and "when is the raw text shown" now have one implementation. The wrapper is found
# under the caller's `here` (the .dsh directory both hooks resolve), else under gate_root.
dsh_check_through_wrapper() {
  _cw_label=$1; _cw_mill=$2; shift 2
  _cw_logout=$(mktemp "${TMPDIR:-/tmp}/dsh-logpath.XXXXXX") || _cw_logout=''
  DSH_CHECK_SHOWN=$(DSH_FEEDBACK_LOG_OUT="$_cw_logout" sh "${here:-$(gate_root)/.dsh/engine}/hooks/feedback.sh" --selector "$_cw_label" -- "$_cw_mill" --ticker false --color false "$@" 2>&1)
  DSH_CHECK_RC=$?
  DSH_CHECK_RAW=''
  _cw_logp=''
  [ -n "$_cw_logout" ] && { _cw_logp=$(cat "$_cw_logout" 2>/dev/null); rm -f "$_cw_logout"; }
  [ -n "$_cw_logp" ] && [ -f "$_cw_logp" ] && DSH_CHECK_RAW=$(cat "$_cw_logp")
  [ -n "$DSH_CHECK_RAW" ] || DSH_CHECK_RAW=$DSH_CHECK_SHOWN
  case "$DSH_CHECK_SHOWN" in
    UNREADABLE:*|INFRA:*|*"
UNREADABLE:"*|*"
INFRA:"*) DSH_CHECK_SHOWN=$DSH_CHECK_RAW ;;
  esac
  return "$DSH_CHECK_RC"
}

# --- the session baseline (F61) --------------------------------------------------------------
# The turn-end gate has to answer for what THIS SESSION changed, not for what the working tree
# happens to contain: uncommitted work that predates the session is not the agent's to answer for.
# `.dsh/engine/hooks/baseline.sh` records, once per session at SessionStart, the dirty `.scala`/`.sc`/`.mill`
# paths and a content hash for each; the gate then checks a path that was already dirty only when its
# content changed since, and always checks a path that is new since the baseline.
#
# Both hooks derive "what is dirty" through `dsh_touched_files` and hash through `dsh_file_hash`, so
# the two sides of that comparison cannot drift apart — a baseline hashed one way and compared
# another would silently either check everything or check nothing.
#
# The record is one file per session, `.dsh/.state/baseline-<key>.tsv`: a `#` header line naming the
# session and the moment it was taken, then `<sha256|->` TAB `<path>` per dirty path. `-` is the hash
# of a path with no readable file, so a file that was already deleted when the session started and is
# still deleted compares equal. A session that starts on a clean tree still gets the file (with no
# rows): "clean at the start" is a fact the gate needs, and an absent file means "no baseline".

# The state-file key for a session id: never empty, and never a path the id can steer (`/`, `..`).
dsh_state_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

dsh_baseline_file() { printf '%s\n' "$(state_dir)/baseline-$(dsh_state_key "${1:-}").tsv"; }

# Is a baseline record usable at all? It has to exist and start with the header line every baseline is
# written with. An unreadable or foreign file at that path must never be read as "no rows", because
# "no rows" means "the tree was clean at SessionStart" — a false scope statement about the session.
# A caller that gets a non-zero here falls back to the tree-based rule and says so.
dsh_baseline_readable() { # <baseline-file>
  [ -f "${1:-}" ] || return 1
  _hdr=$(head -n 1 "$1" 2>/dev/null | cut -c1-23)
  [ "$_hdr" = '# DSH session baseline ' ]
}

# How many paths a baseline records: its `#` header line is not one. Zero for a missing or unreadable
# file as well — callers that need to tell those apart ask `dsh_baseline_readable` first.
dsh_baseline_rows() {
  if [ ! -f "${1:-}" ]; then
    printf '0\n'
    return 0
  fi
  awk -F'\t' 'NF >= 2' "$1" 2>/dev/null | wc -l | tr -d ' '
}

# Is there a sha256 tool at all? Without one `dsh_file_hash` answers `-` for every file, and `-` = `-`
# would read as "unchanged since SessionStart" — so the comparison is meaningless and the gate has to
# fall back to checking the whole tree rather than skip paths it cannot compare.
dsh_has_hasher() {
  command -v shasum >/dev/null 2>&1 && return 0
  command -v sha256sum >/dev/null 2>&1 && return 0
  return 1
}

# The sha256 of a readable file, or `-` when there is none (deleted, unreadable, or no hasher).
dsh_file_hash() {
  if [ -f "${1:-}" ]; then
    if command -v shasum >/dev/null 2>&1; then
      shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
      return 0
    fi
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$1" 2>/dev/null | awk '{print $1}'
      return 0
    fi
  fi
  printf '%s\n' '-'
}

# sha256 of stdin, hex only. Callers check dsh_has_hasher first.
dsh_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
}

# The engine's tree hash (spec 2026-09-26 §2): sha256 over the sorted relative file list and each file's
# bytes, the top-level STAMP and every .DS_Store excluded. `-` when there is no hasher.
dsh_engine_tree_hash() {
  dsh_has_hasher || { printf '%s\n' '-'; return 0; }
  ( cd "$1" 2>/dev/null || exit 1
    find . -type f ! -path ./STAMP ! -name .DS_Store | LC_ALL=C sort | while IFS= read -r _f; do
      printf '%s\n' "$_f"; cat "$_f"
    done ) | dsh_sha256_stdin
}

# The template-only paths (spec 2026-09-26 §2, fix round 2): part of scala-llm-template's kit/harness but
# never of a vendored engine. install.sh strips them from the copy it vendors, and check-harness group G
# strips them from the template before comparing -- one list, so the two cannot drift apart. A vendored
# tests/install-test.sh would call a vendored install.sh, which refuses to run (exit 5); the second-project
# smoke needs the template's install.sh and kit/recipes/mill.md, so it cannot run from a vendored copy either.
dsh_engine_template_only() { printf '%s\n' seed install.sh tests/install-test.sh tests/smoke-second-project.sh; }

# dsh_fixture_shape_gaps <engine>: check-harness C1's second shape assertion, here so the template's own
# lib-test runs it too (2026-09-29: sixteen fixtures wrote into directories a clone does not have, and only
# a vendored project's check-harness saw it). Prints `count <writers> <destinations>` first, then one line
# per post_git/mutate_between redirect destination whose directory is neither made by that script
# (`mkdir`), nor by the runner (`.git` with git_init, `.dsh/.state`), nor held by a tracked file under the
# case's root/ -- in a clone that directory does not exist and the case fails there only.
dsh_fixture_shape_gaps() {
  _fs_engine=$1; _fs_writers=0; _fs_dirs=0; _fs_bad=''
  for _fs_script in "$_fs_engine"/tests/cases/*/post_git "$_fs_engine"/tests/cases/*/mutate_between; do
    [ -f "$_fs_script" ] || continue
    _fs_writers=$((_fs_writers + 1))
    _fs_case_dir=${_fs_script%/*}
    _fs_case=${_fs_case_dir##*/}
    # Where this script makes directories itself: the first non-flag argument of every `mkdir`, quotes
    # stripped. Comments are cut first, so a `mkdir -p` named in prose does not count.
    _fs_made=$(awk '{ sub(/#.*/, ""); n = split($0, t, /[[:space:]]+/)
                      for (i = 1; i < n; i++) if (t[i] == "mkdir") {
                        for (j = i + 1; j <= n; j++) {
                          if (t[j] ~ /^-/) continue
                          gsub(/^["'"'"']|["'"'"']$/, "", t[j]); sub(/\/$/, "", t[j]); print t[j]; break
                        }
                      } }' "$_fs_script")
    # Every redirect destination (`>` and `>>`, any fd prefix), comments cut, quotes and the runner's
    # own `$SCRATCH_ROOT` prefix stripped -- run.sh substitutes that literally, so it is the scratch
    # root and never a path inside the fixture tree.
    for _fs_target in $(awk '{ sub(/#.*/, ""); n = split($0, t, /[[:space:]]+/)
                                for (i = 1; i < n; i++) if (t[i] ~ /^[0-9]?>>?$/) {
                                  v = t[i + 1]
                                  gsub(/^["'"'"']|["'"'"']$/, "", v)
                                  sub(/^\$SCRATCH_ROOT\//, "", v)
                                  print v
                                } }' "$_fs_script"); do
      _fs_dir=$(dirname -- "$_fs_target")
      [ "$_fs_dir" = "." ] && continue
      _fs_dirs=$((_fs_dirs + 1))
      _fs_ok=0
      for _fs_c in $_fs_made; do
        case "$_fs_dir" in "$_fs_c"|"$_fs_c"/*) _fs_ok=1 ;; esac
      done
      if [ "$_fs_ok" = 0 ]; then
        case "$_fs_dir" in
          # git_init makes the repository (run.sh only runs post_git once that commit exists), and
          # run.sh itself creates the state directory in every scratch root before the tree is copied.
          .git) [ -f "$_fs_case_dir/git_init" ] && _fs_ok=1 ;;
          .dsh/.state) _fs_ok=1 ;;
        esac
      fi
      if [ "$_fs_ok" = 0 ] \
        && [ -n "$(git -C "$_fs_engine" ls-files -- "tests/cases/$_fs_case/root/$_fs_dir" 2>/dev/null | head -n 1)" ]; then
        _fs_ok=1
      fi
      [ "$_fs_ok" = 1 ] || _fs_bad="$_fs_bad
${_fs_script##*/} of case $_fs_case writes to $_fs_target, and $_fs_dir/ is neither created by that script (mkdir -p), nor created by the runner, nor a directory holding a tracked file under root/ -- in a clone it does not exist, and the case fails there only"
    done
  done
  printf 'count %s %s%s\n' "$_fs_writers" "$_fs_dirs" "$_fs_bad"
}

# The tree hash a fresh vendor of <template kit/harness dir> would stamp: a copy with the template-only
# paths removed, hashed like dsh_engine_tree_hash. `-` when there is no hasher or the copy fails.
dsh_engine_template_hash() {
  dsh_has_hasher || { printf '%s\n' '-'; return 0; }
  _th=$(mktemp -d 2>/dev/null) || { printf '%s\n' '-'; return 0; }
  if cp -R "$1/." "$_th/" 2>/dev/null; then
    dsh_engine_template_only | while IFS= read -r _tp; do rm -rf "${_th:?}/$_tp"; done
    dsh_engine_tree_hash "$_th"
  else
    printf '%s\n' '-'
  fi
  rm -rf "$_th"
}

# One field of <engine>/STAMP, or nothing.
dsh_engine_stamp_field() {
  [ -f "$1/STAMP" ] || return 0
  sed -n "s/^$2=//p" "$1/STAMP" | head -1
}

# ok | missing | mismatch | nohasher
dsh_engine_stamp_verdict() {
  [ -f "$1/STAMP" ] || { printf 'missing\n'; return 0; }
  dsh_has_hasher || { printf 'nohasher\n'; return 0; }
  if [ "$(dsh_engine_stamp_field "$1" tree)" = "$(dsh_engine_tree_hash "$1")" ]; then printf 'ok\n'; else printf 'mismatch\n'; fi
}

# Is <engine> the vendored copy of <root>, i.e. physically <root>/.dsh/engine? The template's own runs are not.
dsh_is_vendored_engine() {
  _ve=$(CDPATH= cd -P -- "$1" 2>/dev/null && pwd) || return 1
  _vr=$(CDPATH= cd -P -- "$2/.dsh/engine" 2>/dev/null && pwd) || return 1
  [ "$_ve" = "$_vr" ]
}

# Positive evidence of a non-Mill build (plan ruling): build.sbt or project.scala at the root, and neither
# build.mill nor an executable ./mill. Prints which file; exit 1 when the project is (or may be) Mill.
dsh_non_mill_build() {
  { [ -e "$1/build.mill" ] || [ -x "$1/mill" ]; } && return 1
  [ -e "$1/build.sbt" ] && { printf 'build.sbt\n'; return 0; }
  [ -e "$1/project.scala" ] && { printf 'project.scala\n'; return 0; }
  return 1
}

# What a baseline recorded for a path: its hash (possibly `-`), or the empty string when the path was
# not dirty when the session started — which is what tells the caller "check this one".
dsh_baseline_hash() { # <baseline-file> <path>
  [ -f "${1:-}" ] || return 0
  awk -F'\t' -v p="$2" '$2 == p { print $1; exit }' "$1" 2>/dev/null
}

# `dsh_touched_files <root> <out>`: write the working tree's changed paths that this harness has
# business with, one per line, sorted — `.scala`/`.sc` files that still exist, and `.mill` files
# whether or not they do (a removed build file is still a build change). The source is
# `git status --porcelain -z -uall` (untracked files included, and `-uall` so a file inside a
# brand-new directory is named rather than the directory) plus `git diff --name-only -z HEAD`.
#
# `-z` is not a detail. Without it git C-quotes any path holding a non-ASCII byte (`core.quotePath`
# escapes non-ASCII by default), a backslash, a quote or a tab, and a reader that only strips the
# surrounding quotes drops those paths on the floor: measured before this was fixed, six dirty paths
# came back as two, and a session that created only `é.scala` ended with exit 0, no Mill call and no
# output at all — a touched Scala file the gate answered nothing about. With `-z` nothing is escaped
# and nothing needs unquoting. POSIX sh has no `read -d`, so the NULs are turned into newlines and a
# path containing a literal newline is still split — the one spelling this cannot represent.
#
# Exit status, and what the caller must do with it:
#   0  <out> holds the paths git reported.
#   1  <root> is not a git work tree — there is no tree to read; say so, do not pretend it is clean.
#   2  git is there but reading the working tree FAILED — a caller that reads that as "nothing
#      changed" is the silent allow this status exists to prevent. `dsh_touched_reason` carries the
#      reason for either failure (set before returning).
dsh_touched_files() {
  _dsh_git_changed "${1:-}" "${2:-}.all" "${2:-}.rename"
  _tc=$?
  [ "$_tc" = 0 ] || return "$_tc"
  _root=${1:-}
  _out=${2:-}
  _ren="$_out.rename"
  : > "$_out"
  while IFS= read -r _path; do
    [ -n "$_path" ] || continue
    case "$_path" in
      *.scala|*.sc)
        # A rename's vanished half is dropped by existence, for source files, always.
        [ -f "$_root/$_path" ] || continue ;;
      *.mill)
        # A `.mill` that was simply deleted stays a touched build file — the build changed, and the
        # probe must run — but the vanished half of a RENAME is not a second change: the surviving
        # name already brought the probe in, and reporting both says the build file changed twice.
        if [ ! -f "$_root/$_path" ] && grep -qxF -- "$_path" "$_ren" 2>/dev/null; then
          continue
        fi ;;
      *) continue ;;
    esac
    printf '%s\n' "$_path" >> "$_out"
  done < "$_out.all"
  rm -f "$_out.all" "$_ren" 2>/dev/null
  return 0
}

# `dsh_changed_paths <root> <out>`: the same git read as `dsh_touched_files`, UNFILTERED — every path
# git reports as changed against HEAD or untracked, one per line, sorted and unique: every extension,
# deleted paths included, and BOTH names of a rename or copy (the vanished source is a removal of its
# own here: the post-hoc frozen-path check at turn-end has to see a frozen file moved away). Exit
# status and `dsh_touched_reason` exactly as `dsh_touched_files`.
dsh_changed_paths() {
  _dsh_git_changed "${1:-}" "${2:-}" "${2:-}.rename"
  _tc=$?
  rm -f "${2:-}.rename" 2>/dev/null
  return "$_tc"
}

# `_dsh_git_changed <root> <out> <renames>`: the shared read behind both helpers above. <out> gets
# every path git reported (sorted, unique, unfiltered); <renames> gets both names of every rename or
# copy pair. Exit status and `dsh_touched_reason` as documented on `dsh_touched_files`.
_dsh_git_changed() {
  _root=${1:-}
  _out=${2:-}
  dsh_touched_reason=''
  if ! ( cd "$_root" 2>/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ); then
    dsh_touched_reason="$_root is not a git work tree"
    return 1
  fi
  _z="$_out.status.z"
  _zd="$_out.diff.z"
  _raw="$_out.raw"
  _ren=${3:-"$_out.rename"}
  ( cd "$_root" 2>/dev/null && git status --porcelain -z -uall ) > "$_z" 2>/dev/null
  _sc=$?
  ( cd "$_root" 2>/dev/null && git diff --name-only -z HEAD ) > "$_zd" 2>/dev/null
  _dc=$?
  if [ "$_sc" != 0 ]; then
    dsh_touched_reason="git status --porcelain -z -uall failed in $_root (exit $_sc)"
    rm -f "$_z" "$_zd" 2>/dev/null
    return 2
  fi
  if [ "$_dc" != 0 ]; then
    # A repository with no commit yet has an unborn HEAD, which makes `git diff HEAD` fail while
    # `git status` already reports every file as new. Anything else is a read that failed.
    if ( cd "$_root" 2>/dev/null && git rev-parse --verify --quiet HEAD >/dev/null 2>&1 ); then
      dsh_touched_reason="git diff --name-only -z HEAD failed in $_root (exit $_dc)"
      rm -f "$_z" "$_zd" 2>/dev/null
      return 2
    fi
    : > "$_zd"
  fi
  : > "$_raw"
  : > "$_ren"
  # The porcelain stream is `<XY> <path>` per record, except that a rename or copy adds its other
  # name as the NEXT record with no status field at all. Both names of a pair are noted in `$_ren`:
  # the half that no longer exists is the one that moved away, and it is not a change of its own.
  tr '\0' '\n' < "$_z" | {
    _bare=0
    while IFS= read -r _tok; do
      [ -n "$_tok" ] || continue
      if [ "$_bare" = 1 ]; then
        printf '%s\n' "$_tok" >> "$_raw"
        printf '%s\n' "$_tok" >> "$_ren"
        _bare=0
        continue
      fi
      _this=$(printf '%s' "$_tok" | cut -c4-)
      printf '%s\n' "$_this" >> "$_raw"
      case "$(printf '%s' "$_tok" | cut -c1-2)" in
        *R*|*C*)
          printf '%s\n' "$_this" >> "$_ren"
          _bare=1 ;;
      esac
    done
  }
  tr '\0' '\n' < "$_zd" >> "$_raw"
  sort -u "$_raw" | awk '$0 != ""' > "$_out"
  rm -f "$_raw" "$_z" "$_zd" 2>/dev/null
  return 0
}

# --- diff-scoped verification: the change set (spec 2026-09-24 §2) ------------------------------
# dsh_diff_ranges <diff-file> <out-file>: turn `git diff -U0` hunk headers into the ranges
# `resolve_references` wants — `<path> TAB <start> TAB <end>`, 0-BASED and END-EXCLUSIVE, one row
# per hunk that adds at least one line.
#
# git prints the new-file span as `+<start>[,<count>]`, 1-BASED and INCLUSIVE, so `+42,3` is
# `41 TAB 44` here and a bare `+42` counts 1. `,0` is a pure deletion: there are no new lines to
# check, so it contributes no row — a range of width 0 would make the tool read a whole file.
# The path comes from the `+++ b/<path>` line rather than from `diff --git`, because that line
# carries exactly one path and so survives a path containing a space; `+++ /dev/null` is a deleted
# file and everything under it is dropped.
dsh_diff_ranges() {
  awk '
    /^\+\+\+ / {
      path = substr($0, 5)
      if (path == "/dev/null") { path = "" }
      else { sub(/^b\//, "", path) }
      next
    }
    /^@@ / {
      if (path == "") next
      # The new-file span is the field that starts with `+`; everything after the second `@@` is
      # context git echoes and is never parsed.
      plus = ""
      for (i = 1; i <= NF; i++) if (substr($i, 1, 1) == "+") { plus = substr($i, 2); break }
      if (plus == "") next
      n = split(plus, se, ",")
      start = se[1] + 0
      count = (n > 1) ? se[2] + 0 : 1
      if (count <= 0) next
      printf "%s\t%d\t%d\n", path, start - 1, start - 1 + count
    }
  ' "$1" > "$2" 2>/dev/null || : > "$2"
  return 0
}

# dsh_diff_coordinates <diff-file>: every dependency coordinate an ADDED line of a build file
# introduces, one per line, sorted and deduplicated, in the `org:name:ver` / `org::name:ver` shape
# `cs resolve` is given. `::` is kept as written — it is Mill's and sbt's "append the Scala binary
# version", and the caller passes `cs` the `--scala-version` that makes it resolvable.
#
# Only `+` lines, because a coordinate that was already in the file is not this turn's; only build
# files, because the same text inside a Scala string literal is not a dependency.
dsh_diff_coordinates() {
  awk '
    /^\+\+\+ / {
      path = substr($0, 5)
      sub(/^b\//, "", path)
      isbuild = (path ~ /\.mill$/ || path ~ /\.sbt$/ || path == "build.mill")
      next
    }
    !isbuild { next }
    /^\+\+\+/ { next }
    /^\+/ {
      line = $0
      # Mill: mvn"org::name:ver" / mvn"org:name:ver" (ivy"" is the older spelling of the same thing)
      rest = line
      while (match(rest, /(mvn|ivy)"[^"]+"/)) {
        lit = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sub(/^(mvn|ivy)"/, "", lit); sub(/"$/, "", lit)
        if (lit ~ /:/) print lit
      }
      # sbt: "org" %% "name" % "ver" and "org" % "name" % "ver"
      rest = line
      while (match(rest, /"[^"]+"[ \t]*%%?[ \t]*"[^"]+"[ \t]*%[ \t]*"[^"]+"/)) {
        lit = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        sep = (lit ~ /%%/) ? "::" : ":"
        n = split(lit, parts, /"/)
        # parts[2], parts[4], parts[6] are the three quoted words
        if (n >= 6) print parts[2] sep parts[4] ":" parts[6]
      }
    }
  ' "$1" 2>/dev/null | sort -u
  return 0
}

# dsh_policy_allows <symbol> <module-dir> [root]: is <symbol> one this module MAY name?
# Exit 0 = allowed. Exit 1 = refused, and the offending module's first row's reason is printed on
# stdout so the caller can quote the human's own words back.
#
# A module with no rows in .dsh/policy/allowed-types.tsv has no policy, and so does a project with
# no table at all: the absence of a rule is not a rule. `scala/` and `java/` symbols never reach
# here — the caller allows them from the tool's `origin` before asking.
dsh_policy_allows() {
  _pa_sym=$1; _pa_mod=$2; _pa_root=${3:-$(gate_root)}
  _pa_tsv="$_pa_root/.dsh/policy/allowed-types.tsv"
  [ -f "$_pa_tsv" ] || return 0
  _pa_tab=$(printf '\t')
  _pa_rows=$(awk -F"$_pa_tab" -v m="$_pa_mod" '!/^#/ && NF >= 3 && $1 == m { print $2 "\t" $3 }' "$_pa_tsv" 2>/dev/null)
  [ -n "$_pa_rows" ] || return 0
  _pa_reason=''
  while IFS="$_pa_tab" read -r _pa_prefix _pa_why; do
    [ -n "$_pa_prefix" ] || continue
    [ -n "$_pa_reason" ] || _pa_reason=$_pa_why
    case "$_pa_sym" in
      "$_pa_prefix"*) return 0 ;;
    esac
  done <<EOF
$_pa_rows
EOF
  printf '%s\n' "$_pa_reason"
  return 1
}

# --- memorisation (spec 2026-09-25 §3) ----------------------------------------------------------
# A production construct whose literals are largely the test suite's own inputs and expected outputs
# has learned the tests, not the problem (SpecBench's 2,900-line hash-table "compiler"). The signal is
# OVERLAP with test literals, not size: a MIDI note table and a memorising table look alike by size,
# and only the second one's keys are the test inputs.
#
# .dsh/policy/memorisation.tsv is the human's and frozen. Two row shapes: `key TAB value` sets a
# threshold (min_overlap, min_ratio, trivial_abs); `path TAB construct TAB reason` exempts one
# construct. The exemption is human-only by design: an agent able to exempt its own reward hacking
# would make the check pointless.

# dsh_memo_policy <key> [root]: the threshold, from the table or its default.
dsh_memo_policy() {
  _mp_key=$1; _mp_root=${2:-$(gate_root)}
  _mp_tsv="$_mp_root/.dsh/policy/memorisation.tsv"
  _mp_v=''
  # A table saved from a CRLF editor ends every value in `\r`, which would fail the test below and
  # silently replace a real override with the default: the CR and the blanks around each field are
  # stripped FIRST (dsh_verify_checks notes a CRLF table, and FAILs a row that is still malformed).
  [ -f "$_mp_tsv" ] && _mp_v=$(awk -F'\t' -v want="$_mp_key" '
    { sub(/\r$/, "") }
    !/^#/ && NF == 2 {
      k = $1; v = $2
      gsub(/^ +| +$/, "", k); gsub(/^ +| +$/, "", v)
      if (k == want) r = v
    }
    END { print r }' "$_mp_tsv" 2>/dev/null)
  # A malformed threshold (a typo, not a number) must fall back to the default rather than reach
  # awk: an unvalidated string compared with `>=` against a number sorts lexically, so a garbage
  # min_ratio or min_overlap silently disables the whole check instead of erroring. "Well-formed"
  # means a plain non-negative decimal (8, 0.5, 10, .5) — checked with `case`, not awk coercion.
  case "$_mp_v" in
    '') ;;
    *[!0-9.]*) _mp_v='' ;;
    *.*.*) _mp_v='' ;;
    *[0-9]*) ;;
    *) _mp_v='' ;;
  esac
  if [ -z "$_mp_v" ]; then
    case "$_mp_key" in
      min_overlap) _mp_v=8 ;;
      min_ratio) _mp_v=0.5 ;;
      trivial_abs) _mp_v=10 ;;
    esac
  fi
  printf '%s\n' "$_mp_v"
}

# dsh_memo_allowed <path> <construct> [root]: exit 0 and print the reason when an allow row covers it.
dsh_memo_allowed() {
  _ma_tsv="${3:-$(gate_root)}/.dsh/policy/memorisation.tsv"
  [ -f "$_ma_tsv" ] || return 1
  # The same CR and blank stripping as dsh_memo_policy, so a CRLF row exempts what it names and its
  # reason is printed without a trailing CR.
  _ma_why=$(awk -F'\t' -v p="$1" -v c="$2" '
    { sub(/\r$/, "") }
    !/^#/ && NF >= 3 {
      a = $1; b = $2; r = $3
      gsub(/^ +| +$/, "", a); gsub(/^ +| +$/, "", b); gsub(/^ +| +$/, "", r)
      if (a == p && b == c) { print r; exit }
    }' "$_ma_tsv" 2>/dev/null)
  [ -n "$_ma_why" ] || return 1
  printf '%s\n' "$_ma_why"
  return 0
}

# dsh_memo_judge <prod.tsv> <testvals.txt> [root]: one line per flagged construct —
# `path TAB construct TAB k TAB n TAB samples`. See the plan's rule: judged only when touched, the
# whole construct counted, trivial literals dropped, occurrences counted, allow rows honoured.
dsh_memo_judge() {
  _mj_root=${3:-$(gate_root)}
  _mj_min=$(dsh_memo_policy min_overlap "$_mj_root")
  _mj_ratio=$(dsh_memo_policy min_ratio "$_mj_root")
  _mj_triv=$(dsh_memo_policy trivial_abs "$_mj_root")
  [ -s "$2" ] || return 0
  awk -F'\t' -v min="$_mj_min" -v ratio="$_mj_ratio" -v triv="$_mj_triv" '
    NR == FNR { if (length($0)) test[$0] = 1; next }
    {
      g = $1 "\t" $2
      if ($5 == "1") touched[g] = 1
      num = ($3 == "int" || $3 == "long" || $3 == "double" || $3 == "float")
      if (num) { a = $4 + 0; if (a < 0) a = -a; if (a <= triv) next }
      else if (length($4) <= 1) next
      n[g]++
      if ($4 in test) {
        k[g]++
        if (cnt[g] < 5 && !((g, $4) in seen)) { seen[g, $4] = 1; s[g] = s[g] (cnt[g] ? " | " : "") $4; cnt[g]++ }
      }
    }
    END {
      for (g in n) if (g in touched && k[g] >= min && k[g] / n[g] >= ratio)
        printf "%s\t%d\t%d\t%s\n", g, k[g], n[g], s[g]
    }
  ' "$2" "$1" 2>/dev/null | sort | while IFS="$(printf '\t')" read -r _mj_p _mj_c _mj_k _mj_n _mj_s; do
    dsh_memo_allowed "$_mj_p" "$_mj_c" "$_mj_root" >/dev/null && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$_mj_p" "$_mj_c" "$_mj_k" "$_mj_n" "$_mj_s"
  done
  return 0
}

# dsh_is_test_path <root-relative path> [root]: exit 0 when the path is a VISIBLE test source — under
# its owning module's `test/` directory (the longest moddir prefix in modules.tsv, the classification
# turn-end's `is_test` uses) and not sealed. The holdout is sealed and so never counts: the threat the
# memorisation check guards against is memorising what the agent can see.
dsh_is_test_path() {
  _it_p=$1; _it_root=${2:-$(gate_root)}
  _it_mod=$(awk -F'\t' -v p="$_it_p" '$1 != "" && index(p, $1 "/") == 1 { if (length($1) > length(b)) b = $1 } END { print b }' \
    "$_it_root/.dsh/.state/modules.tsv" 2>/dev/null)
  [ -n "$_it_mod" ] || return 1
  case "$_it_p" in
    "$_it_mod"/test/*) ;;
    *) return 1 ;;
  esac
  [ "$(dsh_frozen_access "$_it_p" "$_it_root" 2>/dev/null)" = sealed ] && return 1
  return 0
}

# dsh_memo_read <answer.json> <requested-list> <out-prefix>: read one `literal_tokens` answer against
# the files that were REQUESTED (one root-relative path per line). The launcher is a process boundary,
# so its answer shape is checked here, not trusted -- the rule resolve_references' `answered` join
# already applies:
#   <prefix>.rows    uri TAB line TAB kind TAB value TAB enclosingKey, one per literal of a REQUESTED
#                    file answered without an error. A row for a file nobody asked about is dropped:
#                    a production value must never count as a test value because it rode in on the
#                    wrong answer.
#   <prefix>.unread  uri TAB reason, sorted, one per requested file whose literals were NOT all read:
#                    the tool's error, no entry in the answer at all, or `omitted` > 0 (the tool caps
#                    each file at 2000 literals and counts the rest there).
# A value's tab or newline is encoded as the two characters `\t` / `\n` before it lands in a row.
# Returns 0 when the answer was read (both files may be empty), 1 when the answer is not a JSON
# literal_tokens answer (no `files` array), 2 when neither jq nor python3 is on PATH.
dsh_memo_read() {
  : > "$3.rows"
  : > "$3.unread"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.files[] | .uri as $u |
      (["F", $u, ((.omitted // 0) | tostring), ((.error // "") | tostring)] | @tsv),
      (if ((.error // "") != "") then empty else
        (.literals // [])[] |
        ["L", $u, (.line|tostring), .kind,
         (.value | tostring | gsub("\t"; "\\t") | gsub("\n"; "\\n")),
         (if .enclosing then "\(.enclosing.kind):\(.enclosing.name):\(.enclosing.line)" else "file" end)]
        | @tsv end)' "$1" > "$3.raw" 2>/dev/null || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" > "$3.raw" 2>/dev/null <<'MEMOPY' || return 1
import sys, json
try:
    d = json.load(open(sys.argv[1]))
    files = d["files"]
    if not isinstance(files, list):
        raise ValueError
except Exception:
    sys.exit(1)
def enc(v): return str(v).replace("\t", "\\t").replace("\n", "\\n")
for f in files:
    u, e = f.get("uri") or "", f.get("error") or ""
    print("\t".join(["F", enc(u), str(f.get("omitted") or 0), enc(e)]))
    if e:
        continue
    for l in f.get("literals") or []:
        en = l.get("enclosing")
        key = "%s:%s:%s" % (en["kind"], en["name"], en["line"]) if en else "file"
        print("\t".join(["L", enc(u), str(l.get("line")), str(l.get("kind")), enc(l.get("value", "")), key]))
MEMOPY
  else
    return 2
  fi
  # The requested list is told apart by FILENAME, not `NR == FNR`, which misreads the second input as
  # the first when the first is empty -- and an empty answer is exactly a case this join exists for.
  awk -F'\t' -v OFS='\t' -v req="$2" -v rows="$3.rows" '
    FILENAME == req { if ($0 != "") want[$0] = 1; next }
    !($2 in want) { next }
    $1 == "F" {
      seen[$2] = 1
      if ($4 != "") print $2, $4
      else if ($3 + 0 > 0) print $2, "only partly read: " $3 " literal(s) past the tool\047s per-file cap were omitted"
      next
    }
    $1 == "L" { print $2, $3, $4, $5, $6 > rows }
    END { for (f in want) if (!(f in seen)) print f, "no entry in the answer" }
  ' "$2" "$3.raw" | sort -u > "$3.unread"
  return 0
}

# --- kernel verification: the frozen registry of verified kernel files ----
# The ScalaSemantic launcher every semantic caller uses (moved from verify-diff.sh, unchanged).
# The launcher is resolved exactly as .dsh/engine/hooks/health.sh resolves it: override, PATH, profile path.
dsh_semantic_launcher() {
  _sl=${SCALASEMANTIC_MCP_LAUNCHER:-}
  if [ -z "$_sl" ]; then
    _sl=$(command -v scalasemantic-mcp 2>/dev/null) || _sl=""
    if [ -n "$_sl" ] && [ ! -f "$_sl" ]; then
      _sl=/Users/viktorskalinins/.local/bin/scalasemantic-mcp
    fi
  fi
  [ -n "$_sl" ] || _sl=/Users/viktorskalinins/.local/bin/scalasemantic-mcp
  printf '%s\n' "$_sl"
}

# .dsh/policy/kernels.tsv — the human's frozen registry of verified kernel files (spec 2026-09-27 §1):
# `<file> TAB <module> TAB <reason>`. Prints `<file>\t<module>` per well-formed row. One leading `./` is
# stripped, so `./core/src/K.scala` names the same file git reports as `core/src/K.scala` (a spelling
# that never equals a touched path would silently disable the vericoding stage); any other spelling
# that is not root-relative is a FAIL in `dsh_kernel_checks`.
dsh_kernels_rows() {
  _kr_tsv="$1/.dsh/policy/kernels.tsv"
  [ -f "$_kr_tsv" ] || return 0
  tr -d '\r' < "$_kr_tsv" | awk -F'\t' '/^[[:space:]]*(#|$)/ {next} NF >= 3 && $1 != "" && $2 != "" {f = $1; sub(/^\.\//, "", f); print f "\t" $2}'
}

dsh_kernel_of() { # <root> <root-relative path>
  dsh_kernels_rows "$1" | awk -F'\t' -v p="$2" '$1 == p {print $2; found=1; exit} END {exit found ? 0 : 1}'
}

# dsh_kernel_checks [root]: one `ok|fail|note` TAB <message> row per rule; exit 1 when any fail.
# check-harness.sh maps the rows onto its ok/bad/note; lib-test.sh drives the function directly —
# the same shape as dsh_verify_checks.
dsh_kernel_checks() {
  _kk_root=${1:-$(gate_root)}
  _kk_tab=$(printf '\t')
  _kk_bad=0

  # rule 1: the kernels table parses, when there is one
  _kk_p="$_kk_root/.dsh/policy/kernels.tsv"
  if [ ! -f "$_kk_p" ]; then
    printf 'note\tno .dsh/policy/kernels.tsv — no kernels are verified\n'
    return 0
  fi

  # rule 2: validate rows (NF >= 3, files exist, modules in map)
  _kk_m="$_kk_root/.dsh/.state/modules.tsv"
  _kk_has_rows=0

  _kk_all_bad=0
  _kk_lineno=0
  while IFS="$_kk_tab" read -r _kk_line; do
    _kk_lineno=$((_kk_lineno + 1))
    # Skip comments and blanks
    case "$_kk_line" in
      '#'*|'') continue ;;
    esac
    _kk_has_rows=1
    _kk_f=$(printf '%s\n' "$_kk_line" | awk -F"$_kk_tab" '{print $1}')
    _kk_m_val=$(printf '%s\n' "$_kk_line" | awk -F"$_kk_tab" '{print $2}')
    _kk_nf=$(printf '%s\n' "$_kk_line" | awk -F"$_kk_tab" '{print NF}')

    # Check field count
    if [ "$_kk_nf" -lt 3 ]; then
      printf 'FAIL\t.dsh/policy/kernels.tsv:%s needs <file> TAB <module> TAB <reason>\n' "$_kk_lineno"
      _kk_all_bad=1; continue
    fi

    # Check the spelling: root-relative, as git reports a path. One leading `./` is tolerated (and
    # stripped by dsh_kernels_rows); an absolute path, a `..` segment or a second `./` never equals a
    # touched path, so the stage would never run for that kernel.
    _kk_fr=${_kk_f#./}
    case "$_kk_fr" in
      /*|./*|..|../*|*/..|*/../*)
        printf 'FAIL\t.dsh/policy/kernels.tsv:%s %s must be a root-relative path like core/src/K.scala\n' "$_kk_lineno" "$_kk_f"
        _kk_all_bad=1; continue ;;
    esac
    _kk_f=$_kk_fr

    # Check file exists
    if [ ! -f "$_kk_root/$_kk_f" ]; then
      printf 'FAIL\t.dsh/policy/kernels.tsv:%s names %s, which does not exist\n' "$_kk_lineno" "$_kk_f"
      _kk_all_bad=1; continue
    fi

    # Check module in map (if map exists)
    if [ -f "$_kk_m" ]; then
      _kk_found=$(awk -F"$_kk_tab" -v m="$_kk_m_val" '$2 == m { found = 1 } END { print found + 0 }' "$_kk_m" 2>/dev/null)
      if [ "$_kk_found" != 1 ]; then
        printf 'FAIL\t.dsh/policy/kernels.tsv:%s names module %s, which is not in the module map (run ./mill moduleMap)\n' "$_kk_lineno" "$_kk_m_val"
        _kk_all_bad=1; continue
      fi
    fi
  done < "$_kk_p"

  # Note if modules.tsv is missing
  if [ ! -f "$_kk_m" ]; then
    printf 'note\t.dsh/.state/modules.tsv is absent — the kernel module column was not checked (run ./mill moduleMap to generate it)\n'
  fi

  # Check if kernels.tsv is frozen
  if [ -n "$(dsh_frozen_reason .dsh/policy/kernels.tsv "$_kk_root" 2>/dev/null)" ]; then
    printf 'ok\t.dsh/policy/kernels.tsv is frozen\n'
  else
    printf 'FAIL\tnot frozen (add to .dsh/frozen-paths): .dsh/policy/kernels.tsv\n'; _kk_all_bad=1
  fi

  # With kernels registered, what the stage trusts must be frozen too (final review F3, F4): the contract
  # snapshots — a re-vendored project keeps its old frozen-paths, since install.sh never overwrites it, so
  # the seed's `.dsh/.state/contracts/**` row may be missing — and the Stainless wiring files, when they
  # exist: an agent that may edit the verify script can make it print OK.
  if [ "$_kk_has_rows" = 1 ]; then
    if [ -z "$(dsh_frozen_reason .dsh/.state/contracts/x.tsv "$_kk_root" 2>/dev/null)" ]; then
      printf 'FAIL\tthe contract snapshots (.dsh/.state/contracts/**) are not frozen — add the row to .dsh/frozen-paths\n'; _kk_all_bad=1
    fi
    for _kk_w in scripts/stainless-verify.sh buildKit/Stainless.mill; do
      [ -f "$_kk_root/$_kk_w" ] || continue
      if [ -z "$(dsh_frozen_reason "$_kk_w" "$_kk_root" 2>/dev/null)" ]; then
        printf 'FAIL\t%s is not frozen — an agent could disable Stainless; add it to .dsh/frozen-paths\n' "$_kk_w"; _kk_all_bad=1
      fi
    done
  fi

  # Probe the launcher if there are kernel rows and no prior FAILs
  if [ "$_kk_has_rows" = 1 ] && [ "$_kk_all_bad" = 0 ]; then
    _kk_l=$(dsh_semantic_launcher)
    _kk_out=$(mktemp 2>/dev/null) || _kk_out=${TMPDIR:-/tmp}/dsh-kk.$$
    _kk_err=$(mktemp 2>/dev/null) || _kk_err=${TMPDIR:-/tmp}/dsh-kk-err.$$
    _kk_hung=0
    dsh_bounded_probe 20 "$_kk_out" "$_kk_err" "$_kk_l" call contract_clauses '{"files":[{"uri":"K.scala","source":"object K"}]}' "$_kk_root" || _kk_hung=1
    if [ "$_kk_hung" = 1 ]; then
      printf 'note\tthe launcher at %s did not answer `call contract_clauses` within 20 s and was killed — the contract guard will stand down\n' "$_kk_l"
    elif ! grep -q '"files"' "$_kk_out" 2>/dev/null; then
      printf 'note\tthe launcher at %s does not answer `call contract_clauses` — reinstall scalasemantic-mcp (./mill installLocal in ScalaSemanticMCP); the contract guard will stand down\n' "$_kk_l"
    else
      printf 'ok\tthe launcher answers `call contract_clauses`\n'
    fi
    rm -f "$_kk_out" "$_kk_err" 2>/dev/null
  fi

  # Report count of kernel files if all checks passed
  if [ "$_kk_all_bad" = 0 ]; then
    _kk_rows=$(dsh_kernels_rows "$_kk_root" | wc -l | tr -d ' ')
    printf 'ok\tkernels.tsv: %s kernel file(s) registered\n' "$_kk_rows"
  fi

  [ "$_kk_all_bad" = 0 ] && return 0 || return 1
}

# --- vericoding: the contract snapshot, the contract guard, and Stainless's output (spec 2026-09-27 §3) ---
# A registered kernel's require/ensuring/decreases are the HUMAN's. `.dsh/engine/hooks/baseline.sh` records
# them at SessionStart (`dsh_contract_file`); the turn-end gate asks ScalaSemanticMCP's `contract_clauses`
# again for the kernels the turn touched and diffs the two (`dsh_contract_diff`): a clause whose `shape`
# changed, or one that is gone, blocks; a def that is new (a lemma, a helper) is allowed.
#
# The snapshot file (`dsh_contract_file`): a `# DSH contract snapshot <sid> <date>` header, one `# file <uri>` line per kernel
# file the tool ANSWERED without error, then `dsh_contracts_tsv` rows. The `# file` lines are what lets
# the guard tell "this file has no contracts" from "this file was never snapshotted" — an absent row in
# a file the snapshot never covered must read as "cannot compare", never as "every contract is new"
# (plan Review Focus 3). Readers skip every `#` line.
#
# Stainless is run by the module's `stainlessVerify --targets …` (kit/recipes/mill §8). `./mill` exits 1
# for the verify script's exit 1 AND exit 2, so the verdict is read off the script's own marker lines
# (kit/recipes/mill/stainless-feasibility.md, "Line patterns"), on output with ANSI colour stripped and
# carriage returns turned into newlines — the tool redraws its progress lines with `\r`.

# One file per session under ONE directory, `.dsh/.state/contracts/<key>.tsv`, because the frozen-paths
# grammar has no `*` glob (a row is a path, a `dir/` or a `prefix/**`): the seed freezes
# `.dsh/.state/contracts/**`, so no agent tool may rewrite a snapshot (a silent pass) or delete it (the
# guard downgraded to a note). The hooks write it directly, which the freeze does not govern.
dsh_contract_file() { printf '%s\n' "$(state_dir)/contracts/$(dsh_state_key "${1:-}").tsv"; }

# dsh_contracts_tsv <json-file>: one `<uri>\t<key>\t<kind>\t<index>\t<shape>\t<text>` row per clause of a
# contract_clauses answer (kind requires|ensuring|decreases; index = position within `requires`, 0 for
# the others; tabs/newlines/CRs in any field become spaces). Exit 1 when the answer is not JSON, 2 when
# neither jq nor python3 is on PATH. A null field is printed empty rather than failing the whole read.
dsh_contracts_tsv() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.files[]? | .uri as $u | .defs[]? | .key as $k |
      ((.requires // []) | to_entries[] | [$u,$k,"requires",(.key|tostring),.value.shape,.value.text]),
      (if .ensuring then [$u,$k,"ensuring","0",.ensuring.shape,.ensuring.text] else empty end),
      (if .decreases then [$u,$k,"decreases","0",.decreases.shape,.decreases.text] else empty end)
      | map((. // "") | tostring | gsub("[\t\n\r]";" ")) | @tsv' "$1" 2>/dev/null || return 1
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" 2>/dev/null <<'CONTRACTPY' || return 1
import sys, json, re
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
def c(v):
    return re.sub(r"[\t\n\r]", " ", "" if v is None else str(v))
for f in (d.get("files") or []) if isinstance(d, dict) else []:
    u = f.get("uri")
    for df in f.get("defs") or []:
        k = df.get("key")
        rows = [[u, k, "requires", str(i), r.get("shape"), r.get("text")] for i, r in enumerate(df.get("requires") or [])]
        for kind in ("ensuring", "decreases"):
            cl = df.get(kind)
            if cl:
                rows.append([u, k, kind, "0", cl.get("shape"), cl.get("text")])
        for r in rows:
            print("\t".join(c(x) for x in r))
CONTRACTPY
  else
    return 2
  fi
  return 0
}

# dsh_contracts_unread <json-file> <uris-file>: `<uri>\t<reason>` for every uri listed in <uris-file> the
# answer does not cover — no entry at all, or an entry carrying an `error` (a file that does not parse).
# Such a file has no rows in `dsh_contracts_tsv`, and reading that as "no contracts" would make a
# snapshot compare as "every contract is new" and a turn-end read as "every contract was removed".
# Exit codes as `dsh_contracts_tsv`.
dsh_contracts_unread() {
  _cu_raw=$(mktemp "${TMPDIR:-/tmp}/dsh-cu.XXXXXX") || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r '.files[]? | [(.uri // "" | tostring), ((.error // "") | tostring | gsub("[\t\n\r]";" "))] | @tsv' "$1" > "$_cu_raw" 2>/dev/null \
      || { rm -f "$_cu_raw"; return 1; }
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" > "$_cu_raw" 2>/dev/null <<'UNREADPY' || { rm -f "$_cu_raw"; return 1; }
import sys, json, re
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
for f in (d.get("files") or []) if isinstance(d, dict) else []:
    print("%s\t%s" % (f.get("uri") or "", re.sub(r"[\t\n\r]", " ", str(f.get("error") or ""))))
UNREADPY
  else
    rm -f "$_cu_raw"
    return 2
  fi
  awk -F'\t' -v OFS='\t' -v req="$2" '
    FILENAME == req { if ($0 != "") { want[$0] = 1; order[++n] = $0 }; next }
    { seen[$1] = 1; if ($2 != "") err[$1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        u = order[i]
        if (!(u in seen)) print u, "no entry in the answer"
        else if (u in err) print u, err[u]
      }
    }' "$2" "$_cu_raw"
  rm -f "$_cu_raw"
  return 0
}

# dsh_contract_call <root> <uris-file> <out-json>: ask the launcher's one-shot `contract_clauses` for
# the listed root-relative files, bounded to 30 s (dsh_bounded_probe: `timeout` is absent on stock
# macOS). Return 0 with the answer in <out-json>, or 1 with the reason in `dsh_contract_reason`.
dsh_contract_call() {
  dsh_contract_reason=''
  _cc_l=$(dsh_semantic_launcher)
  if [ ! -f "$_cc_l" ]; then
    dsh_contract_reason="no scalasemantic-mcp launcher at $_cc_l"
    return 1
  fi
  _cc_req=$(awk '
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    $0 != "" { printf "%s{\"uri\":\"%s\"}", (n++ ? "," : ""), jesc($0) }
    END { }' "$2")
  _cc_req="{\"files\":[$_cc_req]}"
  _cc_err="$3.err"
  if ! dsh_bounded_probe 30 "$3" "$_cc_err" "$_cc_l" call contract_clauses "$_cc_req" "$1"; then
    dsh_contract_reason="$_cc_l call contract_clauses did not answer within 30 s and was killed"
    rm -f "$_cc_err"
    return 1
  fi
  if ! grep -q '"files"' "$3" 2>/dev/null; then
    # The launcher's reason sits beneath the JVM's own `WARNING: … sun.misc.Unsafe` lines (verify-diff).
    _cc_why=$(grep -v '^WARNING:' "$_cc_err" 2>/dev/null)
    [ -n "$_cc_why" ] || _cc_why='(no answer and no reason beyond JVM warnings)'
    dsh_contract_reason="$_cc_l call contract_clauses gave no answer — $(bound_lines "$_cc_why" 3)"
    rm -f "$_cc_err"
    return 1
  fi
  rm -f "$_cc_err"
  return 0
}

# dsh_contract_diff <before.tsv> <after.tsv> <uris-file>: compare two `dsh_contracts_tsv` tables, keyed by
# uri+key+kind+index, for the uris listed in <uris-file> only. Prints, in <before> order,
#   changed TAB <uri> TAB <key> TAB <kind> TAB <old text> TAB <new text>   (the clause's shape differs)
#   removed TAB <uri> TAB <key> TAB <kind> TAB <old text>                  (the clause is gone)
#   unreadable TAB <uri> TAB <key> TAB <kind>                             (either side has neither shape nor text)
# then, in <after> order,
#   added TAB <uri> TAB <key> TAB <kind> TAB <text>                        (a clause new to a def the snapshot had)
# A row only in <after> whose uri+key the snapshot has (a new `requires`/`ensuring`/`decreases` kind, or a
# `requires` appended after the existing ones) is `added`: adding a precondition is how a counterexample is
# made to vanish (final review F1). A row only in <after> for a def the snapshot never saw is ignored: a new
# def with a contract (a lemma) is allowed. A def with no clause at all is not in `contract_clauses`' answer,
# so one gaining its first `require` reads as a new def. `#` lines are skipped.
# When either side's shape is empty the TEXT is compared instead: two empty shapes would otherwise
# compare equal and hide any edit (fix round 1). A clause with neither is unreadable, never "same".
dsh_contract_diff() {
  awk -F'\t' -v OFS='\t' -v uf="$3" -v bf="$1" '
    FILENAME == uf { if ($0 != "") want[$0] = 1; next }
    /^#/ { next }
    FILENAME == bf {
      if (!($1 in want)) next
      k = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
      if (k in bs) next
      bs[k] = $5; bt[k] = $6; bu[k] = $1; bk[k] = $2; bn[k] = $3; order[++n] = k; bdef[$1 SUBSEP $2] = 1
      next
    }
    {
      k = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
      if (!(k in seen) && !(k in bs) && (($1 SUBSEP $2) in bdef)) { add[++na] = "added" OFS $1 OFS $2 OFS $3 OFS $6 }
      as[k] = $5; at[k] = $6; seen[k] = 1
    }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (bs[k] == "" && bt[k] == "") print "unreadable", bu[k], bk[k], bn[k]
        else if (!(k in seen)) print "removed", bu[k], bk[k], bn[k], bt[k]
        else if (as[k] == "" && at[k] == "") print "unreadable", bu[k], bk[k], bn[k]
        else if (bs[k] == "" || as[k] == "") { if (at[k] != bt[k]) print "changed", bu[k], bk[k], bn[k], bt[k], at[k] }
        else if (as[k] != bs[k]) print "changed", bu[k], bk[k], bn[k], bt[k], at[k]
      }
      for (i = 1; i <= na; i++) print add[i]
    }' "$3" "$1" "$2"
}

# --- verification escapes (final review F3) ---------------------------------------------------------
# `assume(`, `@extern` and `@ignore` make Stainless accept a body without proving it, with every clause left
# untouched — so the contract guard cannot see them. SessionStart records each registered kernel's count
# as `# escapes <uri> <n>` in the contract snapshot; the turn-end stage blocks a touched kernel whose count
# went up. A line whose first non-blank characters are `//` or `*` is a comment and is not counted; a
# `/* … */` on one line is (the rule is the spelling, not the parse). Several markers on one line count once.
dsh_escape_lines() { # <file>: `<n>:<line>` per counted line
  [ -f "$1" ] || return 0
  LC_ALL=C awk '/^[[:space:]]*(\/\/|\*)/ { next } /assume\(|@extern|@ignore/ { print NR ":" $0 }' "$1" 2>/dev/null
  return 0
}
dsh_escape_count() { # <file>: the number of counted lines (0 for a missing file)
  _ec=$(dsh_escape_lines "$1" | wc -l | tr -d ' ')
  printf '%s\n' "${_ec:-0}"
}
# dsh_snapshot_escapes <snapshot> <uri>: the count recorded for <uri>, exit 1 (nothing printed) when the
# record has no `# escapes` line for it (a record from an engine older than the count).
dsh_snapshot_escapes() {
  awk -v u="$2" '
    /^# escapes / {
      n = $NF; p = $0; sub(/^# escapes /, "", p); sub(/ [^ ]*$/, "", p)
      if (p == u && n ~ /^[0-9]+$/) { print n; found = 1; exit }
    }
    END { exit found ? 0 : 1 }' "$1" 2>/dev/null
}

# dsh_decimal <value> <default>: <value> as a decimal for `$(( ))` — leading zeros stripped (a lone `0`
# kept), because shell arithmetic reads `08` as a bad octal number and the hook dies on it — or <default>
# when <value> is empty or not all digits.
dsh_decimal() {
  case "$1" in
    ''|*[!0-9]*) printf '%s\n' "$2" ;;
    *) _dd=$(printf '%s' "$1" | sed 's/^0*//'); printf '%s\n' "${_dd:-0}" ;;
  esac
}

# The capture as the parser reads it: CR -> newline, ANSI colour stripped. LC_ALL=C because the tool's
# summary table is drawn with UTF-8 box characters and a locale-aware awk/sed may refuse a byte it does
# not like; every pattern here is ASCII (or matches the UTF-8 bytes literally).
_dsh_stainless_clean() {
  LC_ALL=C tr '\r' '\n' < "$1" 2>/dev/null | LC_ALL=C awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); print }'
}

# dsh_stainless_report <output-file>: the invalid verification conditions, one headline each
# (`INVALID <file>:<line>:<col>: '<vc kind>' VC for <function>`) with its counterexample bindings under it,
# bounded to `max_lines` - 2 lines (and each line to 240 characters: a counterexample can be a whole data
# structure), then `unknown <N>` — N from the summary line, else the count of TIMEOUT/UNKNOWN detail
# lines. Colour-free. Exit 0.
dsh_stainless_report() {
  _sr_clean=$(_dsh_stainless_clean "$1")
  _sr_inv=$(printf '%s\n' "$_sr_clean" | LC_ALL=C awk -v maxb=240 '
    function cut(s) { return length(s) > maxb ? substr(s, 1, maxb) " …" : s }
    /^\[Warning \]  - Result for / {
      head = $0; sub(/^\[Warning \]  - Result for /, "", head); sub(/:[[:space:]]*$/, "", head)
      sub(/ @[0-9]+:[0-9]+$/, "", head); inv = 0; ce = 0; next
    }
    /^\[Warning \] .*:[0-9]+:[0-9]+:  => INVALID[[:space:]]*$/ {
      loc = $0; sub(/^\[Warning \] /, "", loc); sub(/:  => INVALID[[:space:]]*$/, "", loc)
      print cut("INVALID " loc ": " head); inv = 1; next
    }
    inv && /^\[Warning \] Found counter-example:/ { ce = 1; print "  counterexample:"; next }
    ce && /^\[Warning \]   [^:]+: .* -> / { b = $0; sub(/^\[Warning \]   /, "", b); print cut("    " b); next }
    { ce = 0 }')
  _sr_max=$(( ${max_lines:-15} - 2 ))
  [ "$_sr_max" -gt 0 ] || _sr_max=1
  [ -n "$_sr_inv" ] && bound_lines "$_sr_inv" "$_sr_max"
  _sr_unk=$(printf '%s\n' "$_sr_clean" | LC_ALL=C sed -nE 's/.*total:[[:space:]]+[0-9]+[[:space:]]+valid:.*unknown:[[:space:]]+([0-9]+).*/\1/p' | head -n 1)
  if [ -z "$_sr_unk" ]; then
    _sr_unk=$(printf '%s\n' "$_sr_clean" | LC_ALL=C grep -Ec ':[0-9]+:[0-9]+:  => (TIMEOUT|UNKNOWN)[[:space:]]*$')
  fi
  printf 'unknown %s\n' "${_sr_unk:-0}"
  return 0
}

# dsh_stainless_unknowns <output-file>: one line per VC the solver could not decide, from the summary
# table (`<file>:<line>:<col>  <function>  <vc kind>  (timeout|unknown)`), else from the detail lines.
dsh_stainless_unknowns() {
  _su_clean=$(_dsh_stainless_clean "$1")
  _su=$(printf '%s\n' "$_su_clean" | LC_ALL=C sed -nE 's/^\[  Info  \] [^ ]+ ([^ ]+:[0-9]+:[0-9]+):[[:space:]]+([^ ]+)[[:space:]]+(.*[^ ])[[:space:]][[:space:]]+(timeout|unknown)[[:space:]].*/\1  \2  \3  (\4)/p')
  if [ -z "$_su" ]; then
    _su=$(printf '%s\n' "$_su_clean" | LC_ALL=C sed -nE 's/^\[Warning \] (.*:[0-9]+:[0-9]+):  => (TIMEOUT|UNKNOWN)[[:space:]]*$/\1  (\2)/p')
  fi
  [ -n "$_su" ] && printf '%s\n' "$_su"
  return 0
}

# dsh_stainless_errors <output-file>: Stainless's own error records (`[ Error  ] …`, colour-free) with the
# source-context lines printed under them, minus the closing `Stainless terminated with an error.`.
dsh_stainless_errors() {
  _dsh_stainless_clean "$1" | LC_ALL=C awk '
    /^\[ Error  \] Stainless terminated with an error\./ { ctx = 0; next }
    /^\[ Error  \] / { print; ctx = 1; next }
    ctx && /^[[:space:]]/ { print; next }
    { ctx = 0 }'
}

# dsh_stainless_verdict <output-file> <mill exit> [<targets, comma-separated>]: `<class>\t<reason>` where class is
#   invalid  the script's FAILED marker, or a summary with invalid > 0
#   setup    the script's SETUP marker or usage line (reason = its text); the OK marker with a non-zero
#            Mill exit; or no marker at all (a module without StainlessModule, a Mill error) — reason =
#            the first error line Mill printed, else its last line
#   missing  the OK marker, but the pipeline summary names `missing implementations` (a typed `???`
#            body: Stainless treats it as an unconstrained choose and the postcondition "verifies")
#   ok       the OK marker and none of the above
#   rejected what would be `setup`, but Stainless's own `[ Error  ] <file>:<l>:<c>: …` record names one of
#            <targets> (as given, or as the tail of an absolute path): the tool could not compile or
#            extract a kernel — the body left the supported subset, which is the agent's to fix, not a
#            setup failure to walk past (fix round 1). reason = `<target>:<line>` of the first such record.
dsh_stainless_verdict() {
  _sv=$(_dsh_stainless_clean "$1")
  _sv_rej=''
  if [ -n "${3:-}" ]; then
    _sv_rej=$(printf '%s\n' "$_sv" | LC_ALL=C awk -v tg="$3" '
      BEGIN { n = split(tg, t, ",") }
      /^\[ Error  \] .*:[0-9]+:[0-9]+: / {
        s = $0; sub(/^\[ Error  \] /, "", s)
        if (!match(s, /:[0-9]+:[0-9]+: /)) next
        p = substr(s, 1, RSTART - 1); rest = substr(s, RSTART + 1); split(rest, lc, ":")
        for (i = 1; i <= n; i++) {
          if (t[i] == "") continue
          if (p == t[i] || (length(p) > length(t[i]) && substr(p, length(p) - length(t[i])) == "/" t[i])) { print t[i] ":" lc[1]; exit }
        }
      }')
  fi
  _sv_nl='
'
  if printf '%s\n' "$_sv" | LC_ALL=C grep -Eq '^stainless-verify: FAILED — [0-9]+ invalid' \
     || printf '%s\n' "$_sv" | LC_ALL=C grep -Eq 'total:[[:space:]]+[0-9]+[[:space:]]+valid:.*invalid:[[:space:]]+[1-9][0-9]*[[:space:]]'; then
    printf 'invalid\t\n'; return 0
  fi
  _sv_r=$(printf '%s\n' "$_sv" | LC_ALL=C sed -n 's/^stainless-verify: SETUP — //p' | head -n 1)
  if [ -n "$_sv_rej" ] && ! printf '%s\n' "$_sv" | LC_ALL=C grep -q '^stainless-verify: OK — '; then
    printf 'rejected\t%s\n' "$_sv_rej"; return 0
  fi
  if [ -n "$_sv_r" ]; then printf 'setup\t%s\n' "$_sv_r"; return 0; fi
  if printf '%s\n' "$_sv" | LC_ALL=C grep -q '^usage: stainless-verify'; then
    printf 'setup\tthe verify script was run without a target (%s)\n' "$(printf '%s\n' "$_sv" | LC_ALL=C grep -m 1 '^usage: stainless-verify')"
    return 0
  fi
  if printf '%s\n' "$_sv" | LC_ALL=C grep -q '^stainless-verify: OK — '; then
    if [ "${2:-0}" != 0 ]; then
      printf 'setup\tMill exited %s after scripts/stainless-verify.sh reported OK\n' "$2"; return 0
    fi
    if printf '%s\n' "$_sv" | LC_ALL=C awk '/Verification pipeline summary:/ { p = 1; next } p && /missing implementations/ { f = 1 } END { exit !f }'; then
      printf 'missing\t\n'; return 0
    fi
    printf 'ok\t\n'; return 0
  fi
  _sv_r=$(printf '%s\n' "$_sv" | LC_ALL=C grep -m 1 -E '\[error\]|[Ee]rror' | cut -c1-240)
  [ -n "$_sv_r" ] || _sv_r=$(printf '%s\n' "$_sv" | LC_ALL=C awk 'NF { l = $0 } END { print substr(l, 1, 240) }')
  [ -n "$_sv_r" ] || _sv_r='(Mill printed nothing)'
  printf 'setup\tno verdict line from scripts/stainless-verify.sh (Mill exit %s): %s\n' "${2:-?}" "$_sv_r"
  return 0
}

# --- semantic-index coverage, per file (F72; corrected in the fix round) -------------------------
# The semantic guard has to answer one question about one file -- does the SemanticDB index cover
# it? -- and the index answers it by construction: Mill and sbt name each index file after the
# source path it describes, `*/META-INF/semanticdb/<repo-relative source path>.semanticdb`. So the
# covered set is a filename lookup, and it is CACHED here because the question is asked on every
# classified read.
#
# Why the question exists at all, measured in this checkout: the index covers 61 of 164 `.scala`
# sources (37%). An oracle that only asks "is there an index somewhere" (the health verdict) denies
# the text read of the other 103 files while the semantic tools have nothing to answer with --
# exactly the deadlock the guard's escape hatch exists for. `dsh_coverage_scan` records which files
# ARE covered so a caller can stand down, per file, for the rest.
#
# The harness's own trees are pruned exactly as the health probe prunes them (F46): a fixture's
# `root/out/.../Foo.scala.semanticdb` is a real file under the repository root in a checkout, and
# counting it as coverage would be the same lie the health oracle already refuses to tell. `out/`
# and `target/` are deliberately NOT pruned here: that is where the build writes the index.
#
# THE CACHE FORMAT, v2. Line 1 is the header
#
#   # DSH index coverage v2 rows=<n> covered=<n> index=<digest>
#
# and every line after it is one `<source path>` TAB `<index file path>` pair, both RELATIVE to the
# root, sorted and deduplicated. `rows` is the number of those lines, `covered` the number of
# DISTINCT source paths (one source can have two index files -- Mill writes the same tree under
# `classes/` and `data/` -- so the two counts legitimately differ), and `index` is a checksum over
# the pairs.
#
# WHY A FINGERPRINT AND NOT AN MTIME COMPARISON. The first version refreshed when a `.semanticdb`
# was NEWER than the cache, which is one-directional and was wrong in both directions: an index
# restored from a backup (older mtimes) left a stale cache in place, so a covered read was ALLOWED,
# and an index file removed by a `clean` left its entry in the cache, so a read nothing covered any
# more was still DENIED -- F72's deadlock, reintroduced by its own cache. `index=` is taken over the
# index tree's contents, so it moves both ways: a compiled module adds pairs, a cleaned or restored
# tree changes or removes them, and a source appearing or disappearing flips a pair's existence
# filter. A build that extends coverage always changes the set of pairs, which is the same event as
# "a newer `.semanticdb` appeared", stated exactly instead of approximated.
#
# A cache that does not validate -- truncated, foreign, or short of the rows its own header declares
# -- is a MISS and is rebuilt; it is never read as "nothing is covered", which is the permissive
# direction a corrupt cache must not be able to produce.

# <path>: the lexically canonical spelling of a path -- `~/` expanded, `//` collapsed, `.` and `..`
# segments resolved, a trailing slash dropped. Purely lexical: no symlink is resolved (this is about
# SPELLINGS, which is what a command line carries) and nothing has to exist. A leading `..` of a
# relative path stays (`../x`), and `..` above the root of an absolute path is the root.
#
# The guard needs it because the index is keyed by ONE spelling per source while a command line may
# reach the same file several ways (`core/./src/A.scala`, `core//src/A.scala`,
# `core/src/../src/A.scala`, `$root/./A.scala`, `~/repo/A.scala`). Without it each of those looked
# uncovered and the read STOOD DOWN -- more permissive than the rule this file implements.
dsh_canonical_path() {
  _cx_in=${1:-}
  case "$_cx_in" in
    '~') _cx_in=${HOME:-/} ;;
    '~/'*) _cx_in=${HOME:-/}/${_cx_in#'~/'} ;;
  esac
  _cx_abs=0
  case "$_cx_in" in /*) _cx_abs=1 ;; esac
  _cx_out=''
  _cx_ifs=$IFS
  # IFS is narrowed to `/`, so a segment may contain any other character -- spaces included, which
  # this family has to keep working for. `''|.` skips what `//`, a leading `/` and `./` produce.
  #
  # GLOBBING IS OFF for that split, which is not decoration: `$_cx_in` is unquoted (it must be, for
  # the IFS split), and an unquoted expansion is also PATHNAME-expanded against the CALLER's cwd --
  # so `core/*/A.scala` became `core/backend/core/A.scala` in a cwd holding `backend core out`
  # (measured), i.e. this "purely lexical" function was reading the filesystem after all. The
  # caller's own `-f` is restored, so a hook that had it set keeps it.
  _cx_noglob=1
  case $- in *f*) _cx_noglob=0 ;; esac
  [ "$_cx_noglob" = 1 ] && set -f
  IFS=/
  for _cx_seg in $_cx_in; do
    case "$_cx_seg" in
      ''|.) continue ;;
      ..)
        case "$_cx_out" in
          '') [ "$_cx_abs" = 1 ] || _cx_out='..' ;;
          */*) _cx_out=${_cx_out%/*} ;;
          *) _cx_out='' ;;
        esac
        continue ;;
    esac
    if [ -z "$_cx_out" ]; then _cx_out=$_cx_seg; else _cx_out=$_cx_out/$_cx_seg; fi
  done
  IFS=$_cx_ifs
  [ "$_cx_noglob" = 1 ] && set +f
  if [ "$_cx_abs" = 1 ]; then
    printf '/%s\n' "$_cx_out"
  else
    [ -n "$_cx_out" ] || _cx_out=.
    printf '%s\n' "$_cx_out"
  fi
}

# <root> <find expression...>: run find with the harness's own trees pruned. `out/` and `target/`
# are NOT in this list -- see above -- so a caller that must exclude build output adds its own.
dsh_find_pruned() {
  _fp_root=$1
  shift
  find "$_fp_root" \
    \( -name .dsh -o -name .superpowers -o -name .git -o -name node_modules \
       -o -name .worktrees -o -name website \) -prune -o \
    "$@" 2>/dev/null
}

# <root>: every SemanticDB file under it, one per line.
dsh_semanticdb_files() {
  dsh_find_pruned "$1" -path '*/META-INF/semanticdb/*.semanticdb' -print
}

# <root> <reference file>: the SemanticDB files NEWER than it, one per line. Kept for callers that
# want that relation itself; the coverage cache no longer uses it (see the format note above).
dsh_semanticdb_newer_than() {
  dsh_find_pruned "$1" -path '*/META-INF/semanticdb/*.semanticdb' -newer "$2" -print
}

# <root>: every `.scala` source under it, one per line. Build output is pruned as well -- a source
# generated into `out/` or `target/` is not one of this repository's sources, and the coverage
# fraction is about the sources an agent would read.
dsh_scala_source_files() {
  find "$1" \
    \( -name .dsh -o -name .superpowers -o -name .git -o -name node_modules \
       -o -name .worktrees -o -name website -o -name out -o -name target \) -prune -o \
    -name '*.scala' -print 2>/dev/null
}

# <root>: the COVERED PAIRS of the index, one `<source path>` TAB `<index file path>` per line, both
# relative to <root>, sorted and deduplicated. A pair exists only while the file it names does: an
# entry for a source that no longer exists is dropped (a deleted file cannot be read and must not
# inflate the count), and that existence test is part of the fingerprint, so a source that
# disappears is a change like any other.
dsh_coverage_pairs() {
  _cp_root=${1:-}
  dsh_semanticdb_files "$_cp_root" | while IFS= read -r _cp_file; do
    [ -n "$_cp_file" ] || continue
    _cp_idx=${_cp_file#"$_cp_root"/}
    _cp_src=${_cp_idx##*/META-INF/semanticdb/}
    _cp_src=${_cp_src%.semanticdb}
    [ -f "$_cp_root/$_cp_src" ] || continue
    printf '%s\t%s\n' "$_cp_src" "$_cp_idx"
  done | sort -u
}

# <pairs text>: the fingerprint of a pair listing -- `<rows> <digest>`, or `0 none` for an empty
# index. `cksum` (POSIX) rather than a hash tool that may not be installed; the byte count it prints
# is part of the value, and both halves are compared, so a collision would have to match length too.
dsh_coverage_fingerprint() {
  if [ -z "${1:-}" ]; then
    printf '0 none\n'
    return 0
  fi
  _cf_rows=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
  _cf_sum=$(printf '%s\n' "$1" | cksum)
  printf '%s %s\n' "$_cf_rows" "$(printf '%s' "$_cf_sum" | awk '{ print $1 "-" $2 }')"
}

# <cache> <rows|covered|index>: the value the header declares for that field, or the empty string.
dsh_coverage_header_field() {
  awk -v f="${2:-}" '
    NR == 1 {
      if (f == "rows" && match($0, /rows=[0-9]+/)) print substr($0, RSTART + 5, RLENGTH - 5)
      else if (f == "covered" && match($0, /covered=[0-9]+/)) print substr($0, RSTART + 8, RLENGTH - 8)
      else if (f == "index" && match($0, /index=[^ 	]+/)) print substr($0, RSTART + 6, RLENGTH - 6)
    }' "${1:-}" 2>/dev/null
}

# <cache>: 0 when the cache is structurally usable -- a v2 header, then rows of exactly two non-empty
# fields, a source path ending in `.scala`/`.sc` and an index path ending in `.semanticdb`, and as
# many rows as the header declares. That last comparison is what catches a TRUNCATED cache: a file cut
# off after its header would otherwise read as "nothing is covered" and stand a covered read down.
# The model is `module-map.sh` validating its own map, for the same reason.
dsh_coverage_cache_valid() {
  [ -s "${1:-}" ] || return 1
  [ "$(awk 'NR == 1 { print ($0 ~ /^# DSH index coverage v2 rows=[0-9]+ covered=[0-9]+ index=[^ 	]+$/) ? "ok" : "bad" }' "$1" 2>/dev/null)" = ok ] || return 1
  [ "$(awk -v declared="$(dsh_coverage_header_field "${1:-}" rows)" '
      BEGIN { FS = "\t" }
      NR == 1 { next }
      {
        if (NF != 2) bad = 1
        else if ($1 == "" || $2 == "") bad = 1
        else if ($1 !~ /\.(scala|sc)$/) bad = 1
        else if ($2 !~ /\.semanticdb$/) bad = 1
        else rows++
      }
      END { print (bad || rows != declared) ? "bad" : "ok" }
    ' "$1" 2>/dev/null)" = ok ]
}

# <pairs text>: how many DISTINCT sources a pair listing describes -- the number the coverage
# sentence reports, which is not the row count when a source has two index files.
dsh_coverage_count_of() {
  if [ -z "${1:-}" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s\n' "$1" | awk 'BEGIN { FS = "\t" } NF { if (!($1 in seen)) { seen[$1] = 1; n++ } } END { print n + 0 }'
}

# <cache>: how many distinct sources the cached coverage lists.
dsh_coverage_count() {
  if [ ! -f "${1:-}" ]; then
    printf '0\n'
    return 0
  fi
  awk 'BEGIN { FS = "\t" } NR > 1 && NF { if (!($1 in seen)) { seen[$1] = 1; n++ } } END { print n + 0 }' "$1" 2>/dev/null
}

# dsh_coverage_scan <root> <cache>: bring <cache> up to date with the index under <root>.
#
# Current means: the cache validates (header, rows, declared row count), its declared `index`
# fingerprint equals the index tree's fingerprint now, and its declared `covered` count matches.
# Anything else -- a build, a clean, a restore, a truncated or foreign file -- is a rebuild. The
# listing is computed once and written from that same listing, so a rebuild is one walk of the tree;
# a check that finds the cache current is one walk too.
#
# The cache path is the CALLER's, not a fixed `<root>/.dsh/.state/...`: a caller that must not write
# inside the repository (check-harness.sh runs against the checkout itself) can put it in its own
# scratch directory, and a caller that wants the session's shared cache (the read gate, health)
# passes that path. Written through a temp file beside it and renamed, so a reader never sees half a
# list.
dsh_coverage_scan() {
  _cs_root=$(CDPATH= cd -- "${1:-}" 2>/dev/null && pwd -P) || _cs_root=${1:-}
  _cs_cache=${2:-}
  [ -n "$_cs_cache" ] || return 1
  _cs_pairs=$(dsh_coverage_pairs "$_cs_root")
  _cs_fp=$(dsh_coverage_fingerprint "$_cs_pairs")
  _cs_rows=${_cs_fp%% *}
  _cs_digest=${_cs_fp#* }
  _cs_covered=$(dsh_coverage_count_of "$_cs_pairs")
  _cs_stale=1
  if [ -f "$_cs_cache" ] && dsh_coverage_cache_valid "$_cs_cache" \
     && [ "$(dsh_coverage_header_field "$_cs_cache" index)" = "$_cs_digest" ] \
     && [ "$(dsh_coverage_header_field "$_cs_cache" rows)" = "$_cs_rows" ] \
     && [ "$(dsh_coverage_header_field "$_cs_cache" covered)" = "$_cs_covered" ]; then
    _cs_stale=0
  fi
  if [ "$_cs_stale" = 1 ]; then
    _cs_dir=${_cs_cache%/*}
    if [ "$_cs_dir" = "$_cs_cache" ]; then _cs_dir=.; fi
    mkdir -p "$_cs_dir" 2>/dev/null
    _cs_tmp="$_cs_cache.$$"
    {
      printf '# DSH index coverage v2 rows=%s covered=%s index=%s\n' "$_cs_rows" "$_cs_covered" "$_cs_digest"
      if [ -n "$_cs_pairs" ]; then printf '%s\n' "$_cs_pairs"; fi
    } >"$_cs_tmp" 2>/dev/null
    if mv -f "$_cs_tmp" "$_cs_cache" 2>/dev/null; then
      :
    else
      rm -f "$_cs_tmp" 2>/dev/null
    fi
  fi
  return 0
}

# dsh_coverage_covers <root> <cache> <repo-relative source path>: 0 when the index covers that path
# AND the index file the cache names for it still exists. The lookup is anchored to the start of the
# line and to a TAB, so `A.scala` cannot be satisfied by `A.scala.bak` or `src/A.scala` by
# `src/A.scala2`. The existence test is the per-entry half of the invalidation rule -- a cache entry
# is good only while its own index file is there, which is exactly what a `clean` removes -- and it
# also closes the race between the scan and this lookup.
dsh_coverage_covers() {
  _cc_root=${1:-}
  [ -f "${2:-}" ] || return 1
  _cc_paths=$(awk -v p="${3:-}" 'BEGIN { FS = "\t" } index($0, p "\t") == 1 { print $2 }' "$2" 2>/dev/null)
  [ -n "$_cc_paths" ] || return 1
  _cc_ok=''
  _cc_ifs=$IFS
  IFS='
'
  for _cc_one in $_cc_paths; do
    [ -n "$_cc_one" ] || continue
    if [ -f "$_cc_root/$_cc_one" ]; then _cc_ok=1; break; fi
  done
  IFS=$_cc_ifs
  [ -n "$_cc_ok" ]
}

# <root>: how many `.scala` sources the checkout has (the denominator of the coverage fraction).
dsh_scala_source_count() {
  dsh_scala_source_files "${1:-}" | wc -l | tr -d ' '
}

# <root> <cache>: the one sentence every reader of coverage prints -- `index covers 61 of 164 Scala
# sources (37%)`. health.sh puts it in `notes=` and on the context line, check-harness.sh prints it
# as a note, and both read it from here so the two cannot drift apart on the number they report.
dsh_coverage_sentence() {
  _ct_cov=$(dsh_coverage_count "${2:-}")
  _ct_tot=$(dsh_scala_source_count "${1:-}")
  _ct_pct=0
  # Both counts are decimal text by construction; this makes a broken one a reported zero rather
  # than an arithmetic error in a hook (an empty value would make `$((...))` a syntax error).
  case "${_ct_cov:-x}${_ct_tot:-x}" in
    *[!0-9]*) _ct_cov=0; _ct_tot=0 ;;
  esac
  if [ "$_ct_tot" -gt 0 ]; then _ct_pct=$((_ct_cov * 100 / _ct_tot)); fi
  printf 'index covers %s of %s Scala sources (%s%%)\n' "$_ct_cov" "$_ct_tot" "$_ct_pct"
}
# --- frozen paths -----------------------------------------------------------------------------
# A frozen path is a path the HUMAN is working on right now: no agent may write it through the
# routes this gate can see -- the `write`/`edit` tools, a bash write shape, the semantic server's
# annotated-buffer write, and the operand-shaped commands tool-policy answers for (rm/mv/ln/
# truncate/patch/`git checkout|restore|rm|mv|apply`/`perl -i`/`find -delete`). READS STAY ALLOWED:
# the human's in-flight files are still this repository's sources, and a freeze that also blocked
# reading would make the module unreadable rather than protected. (The pre-existing read rules are
# untouched by a freeze: a covered `.scala` text read is still the semantic guard's business, and
# still stands down or denies exactly as it did before.)
#
# WHAT IS OUTSIDE THAT SET, by construction -- this layer matches SPELLINGS, never meaning, and the
# same discipline C-9 states: a path built at run time (`f=...; cp /tmp/x "$f"`), an interpreter
# that opens the file itself (`python3 -c "open(p,'w')"`), a patch whose target lives only inside
# the patch text (`git apply /tmp/p.diff`, `patch < p.diff`), and a SYMLINKED spelling of the path
# (nothing here follows a link). The denial message and `.dsh/engine/README.md` list the same four.
#
# TWO FILES, UNIONED, so a freeze can be either project state or a machine-local decision:
#   * <root>/.dsh/frozen-paths        -- committed: a freeze is project state worth reviewing;
#   * <root>/.dsh/.state/frozen-paths -- gitignored: this machine's addition to it (a machine-local
#     file ADDS freezes; it cannot lift one the committed file makes -- the union is what binds).
#
# One entry per line: a PATH, then a TAB or TWO OR MORE SPACES, then a REASON (the rest of the line,
# required). A single space is NOT a separator, and is a malformed entry: the format could not tell
# `dir with space/A.scala  reason` (one path) from `dir  with space...` (a short path and a reason),
# so a spaced path is written with the wider separator and anything narrower is rejected loudly
# rather than parsed into the wrong freeze. Blank lines, and lines whose first non-blank character
# is `#`, are ignored. Three path shapes:
#
#   engine/details/**              prefix: that directory and everything under it
#   engine/details/                prefix: the same, spelled as a directory
#   engine/details/src/Foo.scala   exact: that one path
#
# The reason is required because a freeze an agent cannot explain to its own user is a freeze the
# agent cannot honour deliberately; every denial quotes it.
#
# A MALFORMED entry is a failure of the INSTALLATION CHECK (`.dsh/engine/check-harness.sh`), never a
# silent skip: no reason; a single-space separator; an absolute path outside the repository; a
# relative path walking out of it; a path naming the repository root; a glob that is not a `/**`
# suffix. A per-call hook cannot enforce what it cannot parse, so it enforces the entries that DID
# parse and stays quiet about the rest -- the FAIL in the installation check is where a human is told.

# dsh_repo_relpath <path> [root]: the repository-relative spelling of <path>, or the empty string
# when it is not a path of this repository -- absolute and outside the root, relative and still
# walking out of it (`../x`), or the root itself. Purely lexical (lib.sh: dsh_canonical_path), and
# the root prefix is stripped in EITHER spelling a session can carry: the one `gate_root` resolved
# and its physical spelling (/tmp and /private/tmp are the same directory on macOS, and a payload
# may name either). The read gate's `repo_relpath` delegates here, so the spelling that resolves to
# a source the index covers and the spelling that resolves to a frozen entry are the same rule.
dsh_repo_relpath() {
  _rr_root=${2:-$(gate_root)}
  _rr_root_phys=$(CDPATH= cd -- "$_rr_root" 2>/dev/null && pwd -P) || _rr_root_phys=$_rr_root
  _rr=$(dsh_canonical_path "${1:-}")
  case "$_rr" in
    "$_rr_root"/*) _rr=${_rr#"$_rr_root"/} ;;
    "$_rr_root_phys"/*) _rr=${_rr#"$_rr_root_phys"/} ;;
    /*) _rr='' ;;
    ..|../*) _rr='' ;;
    .) _rr='' ;;
  esac
  printf '%s\n' "$_rr"
}

# dsh_frozen_paths [root]: the parsed entries, one per line -- <access> TAB <kind> TAB <path> TAB
# <reason>, with access `frozen` (the default, unwritten) or `sealed` (also unreadable) and kind
# `exact` or `prefix`. An unknown leading token is malformed. stdout carries only VALID entries;
# each malformed one is reported on stderr and makes the exit status 1, so a caller that must fail
# loudly can, while a per-call hook keeps deciding with what parsed. Order is the files' own
# (committed first, then machine-local), with byte-identical rows collapsed: the FIRST entry that
# answers for a path is the one whose reason is quoted, so the committed list is the one a human
# reviews -- except a `sealed` entry, which the read verdict (`dsh_sealed_reason`) always prefers
# over a merely `frozen` one for the same path, whichever file said it.
dsh_frozen_paths() {
  _fz_root=${1:-$(gate_root)}
  _fz_root_phys=$(CDPATH= cd -- "$_fz_root" 2>/dev/null && pwd -P) || _fz_root_phys=$_fz_root
  _fz_tab=$(printf '\t')
  _fz_bad=0
  _fz_out=''
  for _fz_file in "$_fz_root/.dsh/frozen-paths" "$_fz_root/.dsh/.state/frozen-paths"; do
    [ -f "$_fz_file" ] || continue
    # Split each line into `<path>` TAB `<reason>` at the first TAB or run of TWO OR MORE spaces --
    # never a single space, which cannot be told from a space inside a path (see the format note
    # above); a line whose only separator is a single space is reported and dropped. Every other
    # shape is judged in the shell below, where the root spellings are known.
    _fz_rows=$(awk -v file="$_fz_file" '
      {
        line = $0
        gsub(/^[ \t]+/, "", line); gsub(/[ \t]+$/, "", line)
        if (line == "" || substr(line, 1, 1) == "#") next
        sep = 0
        for (i = 1; i <= length(line); i++) {
          c = substr(line, i, 1)
          if (c == "\t") { sep = i; break }
          if (c == " " && substr(line, i, 2) == "  ") { sep = i; break }
        }
        if (sep == 0) {
          printf "malformed frozen-path entry in %s: %s — a path and a reason are separated by a TAB or two or more spaces (a single space cannot be told from a space inside a path)\n", file, line > "/dev/stderr"
          bad = 1
          next
        }
        p = substr(line, 1, sep - 1); reason = substr(line, sep)
        gsub(/[ \t]+$/, "", p)
        gsub(/^[ \t]+/, "", reason)
        if (p == "") {
          printf "malformed frozen-path entry in %s: %s — no path before the reason\n", file, line > "/dev/stderr"
          bad = 1
          next
        }
        if (reason == "") {
          printf "malformed frozen-path entry in %s: %s — a freeze needs a reason (the rest of the line)\n", file, line > "/dev/stderr"
          bad = 1
          next
        }
        printf "%s\t%s\n", p, reason
      }
      END { exit bad }' "$_fz_file")
    [ $? = 0 ] || _fz_bad=1
    # The split is unquoted (IFS is a newline, so a path or a reason may contain a space), and an
    # unquoted expansion is also PATHNAME-expanded against this hook's cwd -- so globbing is off
    # around it, exactly as it is in the read gate's coverage loop. `$-` is the caller's.
    _fz_noglob=1
    case $- in *f*) _fz_noglob=0 ;; esac
    [ "$_fz_noglob" = 1 ] && set -f
    _fz_ifs=$IFS
    IFS='
'
    for _fz_row in $_fz_rows; do
      IFS=$_fz_ifs
      # awk's rows are `<path>` TAB `<reason>`; the KIND is this loop's own verdict on the shape.
      _fz_p=${_fz_row%%"$_fz_tab"*}
      _fz_reason=${_fz_row#*"$_fz_tab"}
      _fz_orig=$_fz_p
      # ACCESS: an optional leading token. `sealed` denies reads too; absent means `frozen`
      # (writes only, reads allowed -- every entry before this grammar existed). The awk split
      # above stops at the FIRST separator, so a tagged line lands here as
      # token | "<path><sep><reason>", and the path/reason split is redone once on the remainder.
      _fz_access=frozen
      case "$_fz_p" in
        sealed|frozen)
          _fz_access=$_fz_p
          _fz_rest=$_fz_reason
          _fz_p=''
          # first TAB or run of two+ spaces in the remainder
          _fz_p=$(printf '%s' "$_fz_rest" | awk '
            { line=$0; sep=0
              for (i = 1; i <= length(line); i++) { c = substr(line, i, 1)
                if (c == "\t") { sep = i; break }
                if (c == " " && substr(line, i, 2) == "  ") { sep = i; break } }
              if (sep == 0) { print ""; exit }
              p = substr(line, 1, sep - 1); gsub(/[ \t]+$/, "", p); print p }')
          if [ -z "$_fz_p" ]; then
            printf 'malformed frozen-path entry in %s: %s — an access token (%s) must be followed by a path, a separator and a reason\n' "$_fz_file" "$_fz_row" "$_fz_access" >&2
            _fz_bad=1; continue
          fi
          _fz_reason=$(printf '%s' "$_fz_rest" | awk -v p="$_fz_p" '{ r = substr($0, length(p) + 1); gsub(/^[ \t]+/, "", r); print r }')
          if [ -z "$_fz_reason" ]; then
            printf 'malformed frozen-path entry in %s: %s — a freeze needs a reason (the rest of the line)\n' "$_fz_file" "$_fz_row" >&2
            _fz_bad=1; continue
          fi
          _fz_orig=$_fz_p ;;
        */*|*.*) ;;   # a path: has a slash or a dot; never a token
        *)
          # a bare word where a path should be. It is a mistyped TOKEN only if (a) the remainder
          # still carries a separator of its own AND (b) the remainder's own first field -- the
          # text before THAT separator -- has no space and looks like a path (a `/` or a `.`).
          # `LICENSE<TAB>Ask first.  Do not edit.` fails (b): "Ask first." has a space, so it reads
          # as a reason's first sentence, not a path, and `LICENSE` stays an exact-path freeze.
          # `locked<TAB>core/**<TAB>reason` and `locked<TAB>README.md<TAB>reason` both pass (b) and
          # are rejected as an unknown token. Residual blind spot, accepted: a bare word before a
          # bare *path-shaped-but-dot-less-and-slash-less* filename, e.g. `locked<TAB>LICENSE<TAB>
          # reason`, still parses as exact path `locked` -- (b) cannot tell that case from a plain
          # reason that happens to start with a filename-shaped word.
          case "$_fz_reason" in
            *"$_fz_tab"*|*'  '*)
              _fz_rfield=$(printf '%s' "$_fz_reason" | awk '
                { line=$0; sep=0
                  for (i = 1; i <= length(line); i++) { c = substr(line, i, 1)
                    if (c == "\t") { sep = i; break }
                    if (c == " " && substr(line, i, 2) == "  ") { sep = i; break } }
                  if (sep == 0) { print ""; exit }
                  p = substr(line, 1, sep - 1); gsub(/[ \t]+$/, "", p); print p }')
              case "$_fz_rfield" in
                *' '*|*"$_fz_tab"*) ;;   # has whitespace inside it -- not path-shaped, stays a path
                */*|*.*)
                  printf 'malformed frozen-path entry in %s: %s — unknown access token %s (the grammar knows `sealed` and `frozen`; a bare word before a path and a reason is read as a token)\n' "$_fz_file" "$_fz_row" "$_fz_p" >&2
                  _fz_bad=1; continue ;;
              esac ;;
          esac ;;
      esac
      _fz_kind=exact
      case "$_fz_p" in
        *'/**') _fz_kind=prefix; _fz_p=${_fz_p%'/**'} ;;
        */) _fz_kind=prefix; _fz_p=${_fz_p%/} ;;
      esac
      _fz_p=$(dsh_canonical_path "$_fz_p")
      # The root prefix is stripped in either spelling a session can carry (`gate_root`'s and its
      # physical one: /tmp and /private/tmp are the same directory on macOS), so an absolute entry
      # INSIDE the repository is a legitimate spelling of a repo-relative freeze.
      case "$_fz_p" in
        "$_fz_root"/*) _fz_p=${_fz_p#"$_fz_root"/} ;;
        "$_fz_root_phys"/*) _fz_p=${_fz_p#"$_fz_root_phys"/} ;;
      esac
      case "$_fz_p" in
        "$_fz_root"|"$_fz_root_phys"|'/'|'.'|'')
          printf 'malformed frozen-path entry in %s: %s — names the repository root, which is not a path a freeze can name\n' "$_fz_file" "$_fz_orig" >&2
          _fz_bad=1; continue ;;
        /*)
          printf 'malformed frozen-path entry in %s: %s — an absolute path outside the repository (%s)\n' "$_fz_file" "$_fz_orig" "$_fz_root" >&2
          _fz_bad=1; continue ;;
        ..|../*)
          printf 'malformed frozen-path entry in %s: %s — resolves outside the repository (%s)\n' "$_fz_file" "$_fz_orig" "$_fz_root" >&2
          _fz_bad=1; continue ;;
        *'*'*|*'?'*|*'['*)
          printf 'malformed frozen-path entry in %s: %s — a glob pattern; a freeze is a path, a dir/ or a prefix/**\n' "$_fz_file" "$_fz_orig" >&2
          _fz_bad=1; continue ;;
      esac
      _fz_out="$_fz_out$_fz_access$_fz_tab$_fz_kind$_fz_tab$_fz_p$_fz_tab$_fz_reason
"
    done
    IFS=$_fz_ifs
    [ "$_fz_noglob" = 1 ] && set +f
  done
  # Byte-identical rows collapse; a repeated <kind>/<path> with a DIFFERENT access or reason is kept
  # as its own row -- the union rule (sealed beats frozen) is resolved by the lookup below, which
  # checks sealed rows before frozen ones, not by discarding rows here.
  printf '%s' "$_fz_out" | awk 'NF && !seen[$0]++'
  [ "$_fz_bad" = 0 ]
}

# _dsh_frozen_lookup <want: any|sealed> <path> [root]: the reason (exit 0) when an entry of the
# wanted access answers for the path; nothing and exit 1 otherwise. The path may be spelled any way
# a call spells one -- repo-relative, absolute under the root, `./`-prefixed, `..`-folded,
# `~/`-rooted -- because `dsh_canonical_path` and the two root spellings above make them all name
# the entry the list means. A path that is not a path of this repository never matches: an absolute
# path outside the root and a relative one walking out of it both answer "not frozen", which is the
# same verdict the read gate reaches for them.
#
# A list with a malformed entry answers with the entries that DID parse: what a hook cannot parse
# it cannot enforce, and the loud failure belongs to the installation check (see above).
_dsh_frozen_lookup() {
  _fn_want=${1:-any}
  _fn_path=$(dsh_repo_relpath "${2:-}" "${3:-$(gate_root)}")
  [ -n "$_fn_path" ] || return 1
  _fn_root=${3:-$(gate_root)}
  _fn_rows=$(dsh_frozen_paths "$_fn_root" 2>/dev/null) || :
  dsh_frozen_match "$_fn_want" "$_fn_path" "$_fn_rows" || return 1
  printf '%s\n' "$dsh_frozen_match_reason"
}

# dsh_frozen_match <want: any|sealed> <repo-relative path> <rows>: the matching half of the lookup
# above, over rows `dsh_frozen_paths` already parsed -- so a caller asking about many paths (the
# post-hoc check at turn-end, baseline.sh) parses the list ONCE instead of once per path. No
# subshell, no output: the reason goes to `dsh_frozen_match_reason` (exit 0), or it is emptied and the
# exit is 1. The path must already be repo-relative and canonical (a path git reports is); the
# lookup above canonicalises any other spelling first.
dsh_frozen_match() {
  dsh_frozen_match_reason=''
  _fn_want=${1:-any}
  _fn_path=${2:-}
  _fn_rows=${3:-}
  [ -n "$_fn_path" ] || return 1
  [ -n "$_fn_rows" ] || return 1
  _fn_tab='	'
  _fn_noglob=1
  case $- in *f*) _fn_noglob=0 ;; esac
  [ "$_fn_noglob" = 1 ] && set -f
  _fn_ifs=$IFS
  IFS='
'
  _fn_reason=''
  for _fn_row in $_fn_rows; do
    IFS=$_fn_ifs
    _fn_access=${_fn_row%%"$_fn_tab"*}
    _fn_rest=${_fn_row#*"$_fn_tab"}
    _fn_kind=${_fn_rest%%"$_fn_tab"*}
    _fn_rest=${_fn_rest#*"$_fn_tab"}
    _fn_entry=${_fn_rest%%"$_fn_tab"*}
    _fn_text=${_fn_rest#*"$_fn_tab"}
    if [ "$_fn_want" = any ] || [ "$_fn_want" = "$_fn_access" ]; then
      case "$_fn_kind" in
        exact) [ "$_fn_path" = "$_fn_entry" ] && { _fn_reason=$_fn_text; break; } ;;
        prefix)
          case "$_fn_path" in
            "$_fn_entry"|"$_fn_entry"/*) _fn_reason=$_fn_text; break ;;
          esac ;;
      esac
    fi
  done
  IFS=$_fn_ifs
  [ "$_fn_noglob" = 1 ] && set +f
  [ -n "$_fn_reason" ] || return 1
  dsh_frozen_match_reason=$_fn_reason
  return 0
}

# dsh_frozen_reason <path> [root]: the WRITE verdict -- an entry of any access answers. Contract
# unchanged from before the access column existed: same output, same exit codes.
dsh_frozen_reason() { _dsh_frozen_lookup any "${1:-}" "${2:-$(gate_root)}"; }

# dsh_sealed_reason <path> [root]: the READ verdict -- only a `sealed` entry answers. A merely
# `frozen` entry is not sealed, so a read of it stays allowed.
dsh_sealed_reason() { _dsh_frozen_lookup sealed "${1:-}" "${2:-$(gate_root)}"; }

# dsh_frozen_access <path> [root]: `frozen` or `sealed` for a path the list names (exit 0), nothing
# and exit 1 otherwise. Denial messages quote it so the agent learns which rule it hit.
dsh_frozen_access() {
  if dsh_sealed_reason "${1:-}" "${2:-$(gate_root)}" >/dev/null; then printf 'sealed\n'; return 0; fi
  if dsh_frozen_reason "${1:-}" "${2:-$(gate_root)}" >/dev/null; then printf 'frozen\n'; return 0; fi
  return 1
}

# dsh_gate_written <repo-relative path> [session id]: exit 0 when the path is one the gate ITSELF
# writes while a session runs -- so the post-hoc frozen check (turn-end) and the git-ignored record
# (SessionStart/turn-end, spec 2026-09-28 §1) never read the gate's own bookkeeping as an agent's write
# to a frozen path. ONE list, shared by both: a path missing here blocks every turn once `.dsh/.state`
# is not git-ignored (the seed freezes receipts and modules.tsv); a path listed here too broadly is a
# frozen file nobody compares. `.dsh/.state/frozen-paths` is deliberately ABSENT: it is the human's
# machine-local freeze list, never written by the gate.
#
# With a session id, THIS session's own SessionStart records (`contracts/<key>.tsv`, `frozen/<key>.tsv`)
# are NOT excluded: they are written once, before the session's baseline is taken, so the baseline /
# the frozen hash record holds their hash and any later change to them is exactly the write the freeze
# exists to catch. Other sessions' records (a second session in the same checkout starting up) are.
# A caller passes the session id ONLY when such a hash exists (turn-end: `baseline_state=session`); with
# no comparable record, every session's records -- its own included -- are the gate's own writes.
dsh_gate_written() {
  _gw_p=${1:-}
  case "$_gw_p" in ./*) _gw_p=${_gw_p#./} ;; esac
  if [ -n "${2:-}" ]; then
    # The key is cached per session id: a caller walking hundreds of paths pays one `tr` fork, not one
    # per path.
    if [ "${_gw_sid:-}" != "$2" ] || [ -z "${_gw_k:-}" ]; then
      _gw_sid=$2
      _gw_k=$(dsh_state_key "$2")
    fi
    case "$_gw_p" in
      ".dsh/.state/contracts/$_gw_k.tsv"|".dsh/.state/frozen/$_gw_k.tsv") return 1 ;;
    esac
  fi
  case "$_gw_p" in
    .dsh/.state/receipts) return 0 ;;              # turn-end holdout receipt rows (and prePush's)
    .dsh/.state/modules.tsv|.dsh/.state/modules.tsv.tmp.*) return 0 ;;  # module-map.sh's cache, via a temp + mv
    .dsh/.state/holdout.log) return 0 ;;           # turn-end: the sealed holdout run's full output
    .dsh/.state/unverified.log) return 0 ;;        # turn-end: every released (unverified) turn
    .dsh/.state/health|.dsh/.state/.health.*) return 0 ;;  # health.sh's report, via a temp + mv
    .dsh/.state/index-coverage|.dsh/.state/index-coverage.*) return 0 ;;  # coverage cache (health, semantic-guard), temp + mv
    .dsh/.state/turn-end-*) return 0 ;;            # turn-end's per-session attempt counter
    .dsh/.state/baseline-*) return 0 ;;            # baseline.sh's per-session record
    .dsh/.state/contracts/*) return 0 ;;           # baseline.sh's contract snapshots (other sessions', see above) and their temps
    .dsh/.state/frozen/*) return 0 ;;              # SessionStart's git-ignored frozen hash records (other sessions', see above)
    .dsh/.state/feedback/*) return 0 ;;            # feedback.sh: the raw log of every wrapped Mill run
    .dsh/.state/instructions-missing) return 0 ;;  # feedback.sh: diagnostics with no instruction row
    .dsh/.state/memo-testvals.*) return 0 ;;       # verify-diff.sh: the memorisation check's test-values cache
    .dsh/.state/semantic-fallback.log) return 0 ;; # semantic-guard: every released read, for audit
    .dsh/.state/green/*) return 0 ;;               # post-edit: per-module fastTests green cache, temp + mv
  esac
  return 1
}

# --- git-ignored frozen files (spec 2026-09-28 §1 item 2) -------------------------------------------
# git cannot see a git-ignored file, so the post-hoc check's git read never lists one: the `.dsh/.state`
# records the seed freezes (contract snapshots, receipts, the module map) and any ignored file under a
# frozen row. SessionStart (baseline.sh) hashes every such file into this session's record; turn-end
# re-hashes each recorded file. The record is ALWAYS written on a session's first SessionStart —
# header-only (`# DSH frozen-ignored <sid> <iso>`) when there is nothing to record, the same header plus
# ` incomplete: <reason>` when something could not be recorded — so at turn-end "absent" means "deleted".
# Rows are `<sha256> TAB <repo-relative path>`. It is itself frozen by the seed's
# `.dsh/.state/frozen/**` row (check-harness FAILs without it).
dsh_frozen_record_file() { printf '%s\n' "$(state_dir)/frozen/$(dsh_state_key "${1:-}").tsv"; }

# dsh_frozen_ignored_files <root> [session id]: the existing git-ignored FILES a frozen `exact` or
# `prefix` entry answers for, repo-relative, one per line, sorted and unique — minus the gate's own
# writes (`dsh_gate_written`, the ONE list; the session id is passed straight through to it, so with one
# this session's own contract snapshot stays in, and with none every session's records stay out). A
# tracked file is never listed: git sees it, and `git check-ignore` does not report it.
# Exit 0: the list is complete. Exit 1: it may not be — `dsh_frozen_ignored_reason` says why, and
# whatever was found is still printed (a frozen directory that could not be listed completely), or
# nothing at all (git's own answer failed). No frozen rows -> nothing, exit 0.
dsh_frozen_ignored_files() {
  _fi_root=${1:-$(gate_root)}
  _fi_sid=${2:-}
  dsh_frozen_ignored_reason=''
  _fi_rows=$(dsh_frozen_paths "$_fi_root" 2>/dev/null) || :
  [ -n "$_fi_rows" ] || return 0
  _fi_tmp=$(mktemp -d 2>/dev/null) || {
    dsh_frozen_ignored_reason='no temporary directory could be made'
    return 1
  }
  _fi_tab='	'
  : > "$_fi_tmp/raw"
  while IFS="$_fi_tab" read -r _fi_a _fi_k _fi_p _fi_r; do
    [ -n "$_fi_p" ] || continue
    if [ -f "$_fi_root/$_fi_p" ]; then
      printf '%s\n' "$_fi_p" >> "$_fi_tmp/raw"
    elif [ "$_fi_k" = prefix ] && [ -d "$_fi_root/$_fi_p" ]; then
      # `./`-led so a path starting with `-` is never read as an option.
      if ! ( cd "$_fi_root" 2>/dev/null && find "./$_fi_p" -type f -print ) > "$_fi_tmp/found" 2>/dev/null; then
        dsh_frozen_ignored_reason="${dsh_frozen_ignored_reason:+$dsh_frozen_ignored_reason; }the frozen directory $_fi_p could not be listed completely"
      fi
      sed 's|^\./||' "$_fi_tmp/found" >> "$_fi_tmp/raw"
    fi
  done <<FI_ROWS
$_fi_rows
FI_ROWS
  awk 'NF' "$_fi_tmp/raw" | sort -u > "$_fi_tmp/cand"
  if [ -s "$_fi_tmp/cand" ]; then
    # Exit 0 (some ignored) and 1 (none) are both answers; anything else — not a work tree, a path
    # beyond a symlink — is not, and must never read as "nothing is ignored".
    ( cd "$_fi_root" 2>/dev/null || exit 128
      tr '\n' '\0' < "$_fi_tmp/cand" | git check-ignore --stdin -z ) > "$_fi_tmp/ign.z" 2> "$_fi_tmp/err"
    _fi_rc=$?
    case "$_fi_rc" in
      0|1)
        tr '\0' '\n' < "$_fi_tmp/ign.z" > "$_fi_tmp/ign"
        while IFS= read -r _fi_p; do
          [ -n "$_fi_p" ] || continue
          dsh_gate_written "$_fi_p" "$_fi_sid" && continue
          printf '%s\n' "$_fi_p"
        done < "$_fi_tmp/ign" ;;
      *)
        dsh_frozen_ignored_reason="${dsh_frozen_ignored_reason:+$dsh_frozen_ignored_reason; }git check-ignore failed (exit $_fi_rc): $(head -n 1 "$_fi_tmp/err" 2>/dev/null)" ;;
    esac
  fi
  rm -rf "$_fi_tmp" 2>/dev/null
  [ -z "$dsh_frozen_ignored_reason" ]
}

# dsh_hash_files <root> <list> <out>: <out> gets `<sha256> TAB <path>` for every path of <list> (one
# repo-relative path per line) that could be hashed; a path that could not (gone, unreadable, no hasher)
# is ABSENT, never guessed. One hasher run over the whole list (`xargs`), not one fork per file: 3000
# files cost ~11 ms each through `dsh_file_hash` on macOS, which a 60 s hook timeout does not survive.
# The hasher is `dsh_file_hash`'s (shasum first, then sha256sum), so a row here equals that function's
# answer for the same file. Names are passed `./`-led (a leading `-` is never an option) and read back
# from each output line after the 64-hex hash and its two-character separator; a line is taken only when
# its name is one that was asked for, once, so no hash is ever attributed to another path. A name with a
# backslash (which the hashers escape in their output) and every path the batch did not answer go
# through `dsh_file_hash` one by one. Exit 0; 1 when there is no hasher at all (<out> empty).
dsh_hash_files() {
  _hf_root=${1:-}
  _hf_list=${2:-}
  _hf_out=${3:-}
  : > "$_hf_out"
  if command -v shasum >/dev/null 2>&1; then
    _hf_cmd='shasum -a 256'
  elif command -v sha256sum >/dev/null 2>&1; then
    _hf_cmd=sha256sum
  else
    return 1
  fi
  awk 'NF && index($0, "\\") == 0 { print "./" $0 }' "$_hf_list" | tr '\n' '\0' > "$_hf_out.z"
  : > "$_hf_out.raw"
  if [ -s "$_hf_out.z" ]; then
    # shellcheck disable=SC2086
    ( cd "$_hf_root" 2>/dev/null && xargs -0 $_hf_cmd < "$_hf_out.z" ) > "$_hf_out.raw" 2>/dev/null
  fi
  awk -v want="$_hf_list" '
    FILENAME == want { if (NF) w[$0] = 1; next }
    {
      h = substr($0, 1, 64); sep = substr($0, 65, 2); p = substr($0, 67)
      if (length(h) != 64 || h ~ /[^0-9a-f]/) next
      if (sep != "  " && sep != " *") next
      if (substr(p, 1, 2) != "./") next
      p = substr(p, 3)
      if (!(p in w) || (p in done)) next
      done[p] = 1
      printf "%s\t%s\n", h, p
    }' "$_hf_list" "$_hf_out.raw" > "$_hf_out.ok"
  cut -f2- "$_hf_out.ok" > "$_hf_out.done"
  cat "$_hf_out.ok" > "$_hf_out"
  # Everything the batch did not answer, one by one: a backslash name, a file the batch could not read.
  awk -v d="$_hf_out.done" 'FILENAME == d { ok[$0] = 1; next } NF && !($0 in ok)' "$_hf_out.done" "$_hf_list" \
    > "$_hf_out.rest"
  while IFS= read -r _hf_p; do
    [ -n "$_hf_p" ] || continue
    _hf_h=$(dsh_file_hash "$_hf_root/$_hf_p")
    _hf_h=${_hf_h#\\}
    case "$_hf_h" in ''|-) continue ;; esac
    printf '%s\t%s\n' "$_hf_h" "$_hf_p" >> "$_hf_out"
  done < "$_hf_out.rest"
  rm -f "$_hf_out.z" "$_hf_out.raw" "$_hf_out.ok" "$_hf_out.done" "$_hf_out.rest" 2>/dev/null
  return 0
}

# dsh_frozen_record_checks [root]: the installation rule for the record above, one `ok|FAIL` TAB
# <message> row (check-harness maps it); exit 1 on FAIL. With any frozen row, the records must be
# frozen themselves: turn-end trusts them as the human's, and a re-vendored project keeps its old
# frozen-paths (install.sh never overwrites it), so the seed's row may be missing. No frozen rows ->
# nothing is recorded or compared, so nothing to say.
dsh_frozen_record_checks() {
  _fr_root=${1:-$(gate_root)}
  [ -n "$(dsh_frozen_paths "$_fr_root" 2>/dev/null)" ] || return 0
  if [ -n "$(dsh_frozen_reason .dsh/.state/frozen/x.tsv "$_fr_root" 2>/dev/null)" ]; then
    printf 'ok\tthe frozen-path hash records (.dsh/.state/frozen/**) are frozen\n'
    return 0
  fi
  printf 'FAIL\tthe frozen-path hash records (.dsh/.state/frozen/**) are not frozen — add the row to .dsh/frozen-paths\n'
  return 1
}

# --- the build contract ----------------------------------------------------------------------
# `.dsh/contract` names the commands the gate may run, one `key = value` per line. The gate never
# learns a build tool's name: it runs the value. Blank lines and `#` lines are ignored; the first
# line whose key matches wins; whitespace around key and value is trimmed.
# dsh_contract_get <key> [root]: the value (exit 0), or nothing and exit 1 when absent.
dsh_contract_get() {
  _cg_file="${2:-$(gate_root)}/.dsh/contract"
  [ -f "$_cg_file" ] || return 1
  _cg_val=$(awk -v k="${1:-}" '
    /^[ \t]*(#|$)/ { next }
    { line = $0; i = index(line, "=")
      if (i == 0) next
      key = substr(line, 1, i - 1); val = substr(line, i + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key == k) { print val; found = 1; exit } }
    END { exit !found }' "$_cg_file") || return 1
  printf '%s\n' "$_cg_val"
}

# dsh_contract_for_module <key> <module> [root]: the contract value with every `<module>` replaced by
# the module id; empty (exit 1) when the key is absent.
dsh_contract_for_module() {
  _cfm_v=$(dsh_contract_get "${1:-}" "${3:-$(gate_root)}") || return 1
  printf '%s\n' "$_cfm_v" | sed "s|<module>|${2:-}|g"
}

# --- holdout: the names-only filter -----------------------------------------------------------------
# dsh_weaver_failures: weaver runner output on stdin -> the report the agent may see. ANSI colour
# escapes are stripped from every line first (real `--ticker false` output wraps the header, the
# `+`/`-` marker and the duration in them, and prints no indentation at all). Counts come from the
# `Total N, Failed M, Passed P` line when one exists; real weaver 0.8.x output never prints one, so
# absent that line, passed/failed are the count of `+`/`-` marker lines from the FIRST listing (before
# the FAILURES banner). A suite header is either a bare fully-qualified name on its own line, or a
# `Running Test Class <fqn>` line; either way its LAST dotted segment must start uppercase (a Scala
# object name), so a bare Mill task path (`holdout.test`, `holdout.test.testForked`, all-lowercase
# segments) standing alone never overwrites the suite. A `+`/`-` marker line only counts, and only
# yields a name, once a suite header has been seen: Mill/scalac pre-suite noise (a compiler diagnostic
# bullet, a suggested-fix diff line) never inflates the counts or synthesises a bogus name. A failing
# test is a `- <name> <ms>` marker line taken from the first listing, so the failure details (assertion
# text, diffs, stack traces) are never read or printed -- nothing else from the input is ever printed.
dsh_weaver_failures() {
  awk '
    BEGIN { plus = 0; minus = 0 }
    { line = $0
      gsub(/\033\[[0-9;]*[A-Za-z]/, "", line)          # ANSI SGR / cursor escapes
      sub(/^\[[^]]*\][ \t]?/, "", line)                # a Mill `[n/m] ` prefix (its own separator only)
      sub(/^[^ \t]*holdout\.test[ \t]+/, "", line)      # a Mill task label
      gsub(/^[ \t]+|[ \t]+$/, "", line)
    }
    line ~ /^\*+FAILURES\*+$/ { in_failures = 1; next }
    line ~ /^Total [0-9]+, Failed [0-9]+, Passed [0-9]+/ {
      split(line, f, /[ ,]+/); failed = f[4]; passed = f[6]; have_total = 1; next }
    in_failures { next }
    line ~ /^Running Test Class / {
      rest = line; sub(/^Running Test Class /, "", rest)
      n = split(rest, seg, "."); if (seg[n] ~ /^[A-Z]/) suite = seg[n]; started = 1; next }
    line ~ /^[A-Za-z_][A-Za-z0-9_.]*$/ {
      n = split(line, seg, "."); if (seg[n] ~ /^[A-Z]/) suite = seg[n]; started = 1; next }
    !started { next }
    line ~ /^\+[ \t]/ { plus++; next }
    line ~ /^-[ \t]/ {
      minus++
      name = line; sub(/^-[ \t]+/, "", name); sub(/[ \t]+[0-9]+ms$/, "", name)
      fails[++nf] = suite "." name; next }
    END {
      if (!have_total) {
        if (plus == 0 && minus == 0) { print "holdout: result unreadable"; exit 0 }
        passed = plus; failed = minus
      }
      if (failed > 0 && nf == 0) { print "holdout: " failed " failed, names unavailable"; exit 0 }
      print "holdout: " passed " passed, " failed " failed"
      for (i = 1; i <= nf; i++) print "  - " fails[i]
    }'
}

# --- feedback: parse ------------------------------------------------------------------------------
# dsh_strip_ansi: stdin -> stdout without SGR/CSI escapes. macOS awk accepts the octal \033 in a regex.
dsh_strip_ansi() { awk '{ gsub(/\033\[[0-9;]*[A-Za-z]/, ""); print }'; }

# dsh_feedback_parse [auto|weaver|scalacheck|munit|scalafix|scalac] [root] [rc]: runner output on stdin ->
# the record stream (spec §1): a `counts` TAB passed TAB failed TAB rawlines header, then one record
# per failure, each a block of TAB rows (kind, suite, name, arg*, message, detail*) ending in a blank line.
#
# Every line is ANSI-stripped, trimmed, and freed of ONE leading `[…]` prefix (Mill's `[n/m]`/`[error]`,
# weaver's `[0]`/`[1]` failure index). The adapter is chosen from the text when `auto`: diagnostics
# first -- a `[SEV][Rule.kind] path:l:c`, `path:l:c: warning: [Rule.kind]`, `Rewriting and linting N
# Scala sources` or `scalafix found N diagnostic(s)` line is scalafix, an `[error|warn] path.scala:l:c`
# line (Mill 1.1's compile reporter) is scalac -- then a `! …: Falsified`/`> ARG_n:` line is plain
# scalacheck, an `==> X ` line is munit, anything else weaver.
#
# Diagnostics (spec 2026-09-20 diagnostic→instruction §2): the scalafix and scalac adapters emit
# `counts TAB 0 TAB 0 TAB rawlines TAB errors TAB warnings` and one `diagnostic` record per finding:
# rows kind, source (scalafix|scalac|wart), code, file (`path:line[:col]`, made relative to `[root]`
# when the path starts with `root/`), message, detail* (scalac only, up to 4 following message lines).
# scalafix: the code is the lint id `[Rule.kind]` as printed (fixStrict `[SEV][Rule.kind] path:l:c
# text`, native `path:l:c: sev: [Rule.kind] text`); a pending rewrite's `--- path.scala` diff header
# is one `scalafix.pending-rewrite` error record, and the diff body, the source line and the caret
# line are never records. scalac: Mill prints `[error] path:l:c`, the source line, the caret line,
# then the message up to a blank; the headline is the message. Ruling 1: Mill's reporter prints no
# Scala 3 error ids, so the code is `scalac.<kind>`, the first row of `.dsh/instructions/scalac-kinds.tsv`
# (under gate_root; `kind TAB awk-regex`, `#` rows skipped) whose regex matches the headline, else
# `scalac.error`/`scalac.warning`. A `[wartremover:Wart] text` headline is `source wart`, code
# `wartremover.<Wart>`, message `text`. An unpositioned `-- Error: …` / `-- Warning: …` headline
# (`cyclic reference involving …`) is its own record too: code `scalac.error`/`scalac.warning`, file
# `-`, message the headline, counted -- EVERY one, not only when nothing else was read. scalac's own
# tally (`one error found`, `N errors found`, and the warning twins) is a floor: when fewer records
# were counted than it says, one more `scalac.error` (`scalac.warning`) record with file `-` and
# message `<N> errors found, <counted> shown — see the raw log` is appended and the header carries N,
# so the block never under-reports a red compile. `Compilation failed` / `A Scalafix test error was
# reported` are never records. A red run that produced NO record and no tally is one infra record
# whose message is the first `[error]`-prefixed line (`core.fix …ScalafixConfigException: Unknown
# rule 'X'`); with no `[error]` line either and a non-zero [rc] (the wrapper passes the command's
# exit status), it is one `unreadable` record -- rc, not the transcript, tells that red run from a
# green one. A JVM exception is infra as for the test adapters.
#
# Weaver (0.8.x, as captured in tests/transcripts): the first listing's `+`/`-` marker lines are the
# counts (weaver prints no `Total` line); the FAILURES block repeats each `- <name> <ms>` line and
# indents the failure text under it. A weaver-scalacheck failure prints ONE line
# `Property test failed on try N with seed Seed.fromBase64("…") and input <value> (<file>:<line>)`
# and does not shrink: `<value>` becomes `arg ARG_0 <value>`, no `_ORIGINAL`, the record is a
# `property`, and the message is `Property test failed on try N: <first following line>` (the
# assertion). A plain expect failure's message is its first non-blank line (`assertion failed (…)`).
# The seed never reaches a message. A listing cut off before FAILURES still yields one bare record
# per `-` line, with `message -`: the indented text under a listing's `-` entry is dropped, since
# only the FAILURES block is read for messages. Plain scalacheck: `! <name>: <message>` opens a property record, `> ARG_n[_ORIGINAL]:
# <value>` rows are its args. munit: `==> X <suite>.<name> <secs> <message>` opens a test record.
#
# Infra: an exception/compile-failure/no-tests line seen OUTSIDE a failure block marks the run
# broken unless a suite header follows it (this sandbox prints a benign NoClassDefFoundError at every
# Mill test start, before the first `Running Test Class`), or a test-result marker (`+`/`-`, `!`,
# `==> X`) follows a candidate that carried NO `at`/`Caused by` rows (an app log line such as
# `Error: connection refused` between two `+` lines is noise; an exception with a stack trace that
# a `-` marker follows, with no new suite header, is a crash). When it stands, the single infra record
# (message = that line, up to 6 `at`/`Caused by` details) replaces every other record. With nothing
# recognised at all the stream is one `unreadable` record.
dsh_feedback_parse() {
  _fp_adapter=${1:-auto}
  _fp_root=${2:-}
  _fp_rc_in=${3:-}
  _fp_tmp=$(mktemp "${TMPDIR:-/tmp}/dsh-feedback.XXXXXX") || return 1
  dsh_strip_ansi > "$_fp_tmp"
  _fp_raw=$(wc -l < "$_fp_tmp" | tr -d ' ')
  if [ "$_fp_adapter" = auto ]; then
    # Diagnostics first: a scalafix or Mill-compile transcript never carries a test marker, and a test
    # transcript never carries a `[SEVERITY][Rule…] path:l:c` (uppercase severity; Mill's `[error] path:l:c` is scalac) or `path:l:c: warning: [Rule…]` line.
    if grep -Eq '^[ \t]*\[[A-Z]+\]\[[A-Za-z0-9_.-]+\] [^ ]+:[0-9]+:[0-9]+( |$)|^[^ ]+\.scala:[0-9]+:[0-9]+: (warning|error|info): \[|^[ \t]*(Rewriting and linting|Linting) [0-9]+ Scala sources|scalafix found [0-9]+ diagnostic' "$_fp_tmp"; then _fp_adapter=scalafix
    elif grep -Eq '^[ \t]*\[(error|warn)\] [^ ]+\.(scala|java):[0-9]+:[0-9]+[ \t]*$' "$_fp_tmp"; then _fp_adapter=scalac
    elif grep -Eq '^[ \t]*(\[[^]]*\][ \t]*)?(! .*: Falsified|> ARG_[0-9])' "$_fp_tmp"; then _fp_adapter=scalacheck
    elif grep -Eq '^[ \t]*(\[[^]]*\][ \t]*)?==> X ' "$_fp_tmp"; then _fp_adapter=munit
    else _fp_adapter=weaver; fi
  fi
  _fp_kinds="${_fp_root:-$(gate_root 2>/dev/null)}/.dsh/instructions/scalac-kinds.tsv"
  [ -f "$_fp_kinds" ] || _fp_kinds=/dev/null
  awk -v adapter="$_fp_adapter" -v raw="$_fp_raw" -v root="$_fp_root" -v kinds_file="$_fp_kinds" -v rc="$_fp_rc_in" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function soft_clear() { if (ndet == 0) infra_pending = 0 }   # a test marker outranks a stackless candidate
    function open_rec(kind, suite_, name_) {
      flush_rec(); rec_kind = kind; rec_suite = suite_; rec_name = name_; nargs = 0 }
    function flush_rec() {
      if (rec_kind == "") return
      recs = recs "kind\t" rec_kind "\nsuite\t" (rec_suite == "" ? "-" : rec_suite) "\nname\t" rec_name "\n" rec_args \
             "message\t" (rec_msg == "" ? "-" : rec_msg) "\n\n"
      rec_kind = ""; rec_suite = ""; rec_name = ""; rec_args = ""; rec_msg = ""
    }
    # --- diagnostics (scalafix / scalac / wart) ------------------------------------------------------
    function relpath(p) { if (root != "" && index(p, root "/") == 1) return substr(p, length(root) + 2); return p }
    function open_diag(src, code, file, msg) {
      flush_diag(); d_src = src; d_code = code; d_file = relpath(file); d_msg = msg; d_ndet = 0; d_det = ""; d_open = 1
      if (d_sev == "error") errors++; else warnings++
    }
    function flush_diag() {
      if (!d_open) return
      recs = recs "kind\tdiagnostic\nsource\t" d_src "\ncode\t" d_code "\nfile\t" d_file "\nmessage\t" (d_msg == "" ? "-" : d_msg) "\n" d_det "\n"
      d_open = 0; d_msg = ""; d_det = ""; d_ndet = 0
    }
    function scalac_kind(headline,   k) {
      for (k = 1; k <= nkinds; k++) if (headline ~ kind_re[k]) return kind_name[k]
      return (d_sev == "error" ? "error" : "warning")
    }
    BEGIN { passed = 0; failed = 0; plus = 0; minus = 0; have_total = 0; started = 0; in_failures = 0; nlist = 0; ndet = 0; infra_pending = 0
      errors = 0; warnings = 0; d_open = 0; d_sev = "warning"; want_caret = 0; want_msg = 0; nkinds = 0; d_nerr = 0; d_nwarn = 0; d_first_error = ""
      if (kinds_file != "/dev/null") while ((getline kl < kinds_file) > 0) {
        if (kl ~ /^#/ || kl == "") continue
        ti = index(kl, "\t"); if (ti == 0) continue
        nkinds++; kind_name[nkinds] = substr(kl, 1, ti - 1); kind_re[nkinds] = substr(kl, ti + 1)
      }
    }
    {
      orig = trim($0); gsub(/\t/, " ", orig)
      line = orig; sub(/^\[[^]]*\][ \t]?/, "", line); line = trim(line)
      # --- scalafix: fixStrict `[SEV][Rule.kind] path:l:c text`, native `path:l:c: sev: [Rule.kind] text`,
      #     and a pending rewrite`s `--- path` diff header. Source/caret/diff-body lines are not records;
      #     every consumed line `next`s; the shared block after the scalac adapter decides what the infra
      #     rule may see.
      if (adapter == "scalafix") {
        if (orig ~ /^\[(WARNING|ERROR|INFO)\]\[[A-Za-z0-9_.-]+\] [^ ]+:[0-9]+:[0-9]+( |$)/) {
          d_sev = (orig ~ /^\[ERROR\]/) ? "error" : "warning"
          rest = orig; sub(/^\[[A-Z]+\]\[/, "", rest); code = rest; sub(/\].*$/, "", code)
          sub(/^[^]]*\] /, "", rest); file = rest; sub(/ .*$/, "", file); msg = rest; sub(/^[^ ]+ ?/, "", msg)
          open_diag("scalafix", code, file, msg); flush_diag(); next
        }
        if (orig ~ /^[^ ]+:[0-9]+:[0-9]+: (warning|error|info): \[[A-Za-z0-9_.-]+\] /) {
          d_sev = (orig ~ /: error: /) ? "error" : "warning"
          file = orig; sub(/: (warning|error|info): .*$/, "", file)
          rest = orig; sub(/^[^ ]+: (warning|error|info): \[/, "", rest); code = rest; sub(/\].*$/, "", code)
          msg = rest; sub(/^[^]]*\] /, "", msg)
          open_diag("scalafix", code, file, msg); flush_diag(); next
        }
        if ($0 ~ /^--- / && orig ~ /^--- [^ ]+\.(scala|sc|java)$/) {
          d_sev = "error"; file = orig; sub(/^--- /, "", file)
          open_diag("scalafix", "scalafix.pending-rewrite", file, "a rewrite is pending: run <module>.fix, then re-read the file"); flush_diag(); next
        }
      }
      # --- scalac (Mill 1.1 reporter): `[error|warn] path:l:c`, the source line, the caret line, then
      #     the message lines up to a blank or the next `[error|warn] ` line. A wart headline is
      #     `[wartremover:Wart] text`.
      if (adapter == "scalac") {
        if (want_msg && (orig == "" || orig ~ /^\[(error|warn)\] /)) { want_msg = 0; flush_diag(); if (orig == "") next }
        if (orig ~ /^\[(error|warn)\] [^ ]+\.(scala|java):[0-9]+:[0-9]+$/) {
          flush_diag(); d_sev = (orig ~ /^\[error\]/) ? "error" : "warning"
          file = orig; sub(/^\[[a-z]+\] /, "", file)
          d_pending_file = file; want_caret = 1; want_msg = 0; next
        }
        if (want_caret) { if (orig ~ /^\^+$/) { want_caret = 0; want_msg = 1 }; next }
        if (want_msg) {
          if (!d_open) {
            if (orig ~ /^\[wartremover:[A-Za-z0-9]+\] /) {
              w = orig; sub(/^\[wartremover:/, "", w); sub(/\].*$/, "", w); msg = orig; sub(/^\[[^]]*\] /, "", msg)
              open_diag("wart", "wartremover." w, d_pending_file, msg)
            } else open_diag("scalac", "scalac." scalac_kind(orig), d_pending_file, orig)
          } else if (d_ndet < 4) { d_det = d_det "detail\t" orig "\n"; d_ndet++ }
          next
        }
      }
      # --- diagnostics, shared: EVERY unpositioned `-- Error: …` / `-- Warning: …` headline is its own
      #     record (`scalac.error`/`scalac.warning`, file `-`), never a fallback -- a `cyclic reference`
      #     next to a positioned warning used to vanish behind the warning while the compile was red.
      #     scalac`s own tally (`one error found`, `N errors found`, the warning twins) is remembered
      #     as a FLOOR that END compares the counted records against; the first `[error]`-prefixed
      #     line is remembered for END`s "red but nothing recognised" infra record. Only a JVM
      #     exception, or its `at`/`Caused by` rows once one is pending, reaches the infra rule.
      if (adapter == "scalafix" || adapter == "scalac") {
        if (orig ~ /^\[error\] / && d_first_error == "") d_first_error = line
        if (line ~ /^-- (\[E[0-9]+\] )?([A-Za-z]+ )*(Error|Warning): /) {
          flush_diag(); want_caret = 0; want_msg = 0
          d_sev = (line ~ /Warning: /) ? "warning" : "error"
          open_diag("scalac", "scalac." d_sev, "-", line); flush_diag(); next
        }
        if (line ~ /^(one|[0-9]+) (error|errors|warning|warnings) found$/) {
          n = (line ~ /^one /) ? 1 : line + 0
          if (line ~ / errors? found$/) d_nerr = n; else d_nwarn = n
          next
        }
        if (line ~ /[Cc]ompilation failed|compile failed|A Scalafix (test|linter) error was reported/) next
        if (!(line ~ /^(Exception in thread|java\.lang\.)/ || (infra_pending && line ~ /^(at |Caused by:|\.\.\. [0-9]+ more)/))) next
      }
      # --- infra: an exception outside any failure block, unless a suite header follows ---------------
      # A Scala 3 diagnostic (`-- [E006] Not Found Error: <file>:<line>:<col>`) is kept whole as the
      # message -- it carries the location -- and is not overwritten by the `Compilation failed` line
      # Mill prints after it (`[error] app.test.compile Compilation failed` / `compilation failed`).
      # `tasks failed` is NOT a marker: Mill prints it after a red test run as well.
      if (!in_failures && rec_kind == "" && line ~ /^(Exception in thread|java\.lang\.(OutOfMemoryError|NoClassDefFoundError|ClassNotFoundException|NullPointerException|StackOverflowError)|[a-z.]*Error: |-- \[E[0-9]+\] .*Error: |.*compile failed|.*[Cc]ompilation failed|[Nn]o tests? (found|to run)|Test framework .* not found)/) {
        if (!(infra_pending && infra_line ~ /^-- \[E[0-9]+\] / && line ~ /[Cc]ompilation failed/)) { infra_line = line; infra_detail = ""; ndet = 0 }
        infra_pending = 1; next }
      if (infra_pending && line ~ /^(at |Caused by:|\.\.\. [0-9]+ more)/) {
        if (ndet < 6) { infra_detail = infra_detail "detail\t" line "\n"; ndet++ }; next }
      # --- counts ------------------------------------------------------------------------------------
      if (line ~ /^Total [0-9]+, Failed [0-9]+/) {
        split(line, f, /[ ,]+/); failed = f[4]; if (f[5] == "Passed") passed = f[6]; else passed = f[2] - f[4]; have_total = 1; next }
      if (line ~ /^Found [0-9]+ failing propert/) next
      # --- suite header (weaver / munit): a bare fqn whose last segment is uppercase ------------------
      if (line ~ /^Running Test Class /) { sub(/^Running Test Class /, "", line); n = split(line, seg, "."); if (seg[n] ~ /^[A-Z]/) suite = line; started = 1; infra_pending = 0; next }
      if (line ~ /^[A-Za-z_][A-Za-z0-9_.]*:?$/) { s = line; sub(/:$/, "", s); n = split(s, seg, "."); if (seg[n] ~ /^[A-Z]/) { suite = s; started = 1; infra_pending = 0 }; next }
      # --- weaver ------------------------------------------------------------------------------------
      if (adapter == "weaver") {
        if (line ~ /^\*+FAILURES\*+$/) { in_failures = 1; nlist = 0; next }
        if (!started) next
        if (line ~ /^\+[ \t]/) { if (!in_failures) plus++; soft_clear(); next }
        if (line ~ /^-[ \t]/) {
          soft_clear()
          name = line; sub(/^-[ \t]+/, "", name); sub(/[ \t]+[0-9.]+(ms|s)$/, "", name)
          if (!in_failures) { minus++; list_suite[++nlist] = suite; list_name[nlist] = name; next }
          open_rec("test", suite, name); next
        }
        if (rec_kind == "" || line == "") next
        # weaver-scalacheck: "Property test failed on try N with seed Seed.fromBase64("…") and input <value> (<loc>)"
        if (line ~ /^Property test failed on try [0-9]+ with seed .* and input /) {
          v = substr(line, index(line, " and input ") + 11); sub(/[ \t]+\([^()]*:[0-9]+\)$/, "", v)
          rec_args = rec_args "arg\tARG_" nargs "\t" v "\n"; nargs++; rec_kind = "property"
          m = line; sub(/ with seed .*$/, "", m); rec_msg = m; msg_open = 1; next
        }
        if (line ~ /^ARG_[0-9]+(_ORIGINAL)?: /) { lbl = line; sub(/: .*$/, "", lbl); v = line; sub(/^ARG_[0-9]+(_ORIGINAL)?: /, "", v)
          rec_args = rec_args "arg\t" lbl "\t" v "\n"; rec_kind = "property"; next }
        if (rec_msg == "") { rec_msg = line; next }
        if (msg_open) { rec_msg = rec_msg ": " line; msg_open = 0; next }
        next
      }
      # --- plain scalacheck --------------------------------------------------------------------------
      if (adapter == "scalacheck") {
        if (line ~ /^! /) { n = line; sub(/^! /, "", n); m = n; sub(/: .*$/, "", n); sub(/^[^:]*: /, "", m)
          open_rec("property", suite, n); rec_msg = m; failed++; soft_clear(); next }
        if (line ~ /^\+ /) { passed++; soft_clear(); next }
        if (line ~ /^> ARG_[0-9]+(_ORIGINAL)?: / && rec_kind != "") { lbl = line; sub(/^> /, "", lbl); sub(/: .*$/, "", lbl); v = line; sub(/^> ARG_[0-9]+(_ORIGINAL)?: /, "", v)
          rec_args = rec_args "arg\t" lbl "\t" v "\n"; next }
        next
      }
      # --- munit -------------------------------------------------------------------------------------
      if (adapter == "munit") {
        if (line ~ /^\+ /) { passed++; soft_clear(); next }
        if (line ~ /^==> X /) { soft_clear(); fq = line; sub(/^==> X /, "", fq); sub(/[ \t].*$/, "", fq)
          n = split(fq, seg, "."); s = fq; sub(/\.[^.]*$/, "", s)
          open_rec("test", (n > 1 ? s : suite), seg[n])
          m = line; sub(/^==> X [^ \t]+[ \t]+([0-9.]+m?s[ \t]*)?/, "", m); rec_msg = m; failed++; next }
        if (rec_kind != "" && rec_msg == "" && line != "") { rec_msg = line; next }
        next
      }
    }
    END {
      flush_rec(); flush_diag()
      if (adapter == "scalafix" || adapter == "scalac") {
        # the floor: scalac said N errors (warnings) and fewer records were read -- one more record
        # points at the raw log, and the header carries scalac`s number, so the block never
        # under-reports a red compile (a headline this parser does not know, a marker-less run)
        if (!infra_pending && d_nerr > errors) {
          recs = recs "kind\tdiagnostic\nsource\tscalac\ncode\tscalac.error\nfile\t-\nmessage\t" d_nerr " errors found, " errors " shown — see the raw log\n\n"; errors = d_nerr }
        if (!infra_pending && d_nwarn > warnings) {
          recs = recs "kind\tdiagnostic\nsource\tscalac\ncode\tscalac.warning\nfile\t-\nmessage\t" d_nwarn " warnings found, " warnings " shown — see the raw log\n\n"; warnings = d_nwarn }
        # a red run with NO record and no tally must not read as green: the first `[error]` line is the
        # infra record (`core.fix …ScalafixConfigException: Unknown rule`, `core.compile Compilation
        # failed`); with no `[error]` line either, a non-zero rc (when the caller passed one) is
        # `unreadable` -- rc, not the transcript, tells a green run from a red one nothing was parsed of
        if (recs == "" && !infra_pending && errors + warnings == 0) {
          if (d_first_error != "") { infra_pending = 1; infra_line = d_first_error; infra_detail = "" }
          else if (rc != "" && rc != 0) { print "counts\t0\t0\t" raw "\t0\t0"; print "kind\tunreadable\nsuite\t-\nname\t-\nmessage\trunner output not recognised\n"; exit 0 }
        }
        print "counts\t0\t0\t" raw "\t" errors "\t" warnings
        if (infra_pending) { print "kind\tinfra\nsuite\t-\nname\t-\nmessage\t" infra_line; printf "%s", infra_detail; print ""; exit 0 }
        printf "%s", recs; exit 0
      }
      if (adapter == "weaver" && !have_total) { passed = plus; failed = minus }
      if (infra_pending) {
        print "counts\t" passed "\t" failed "\t" raw
        print "kind\tinfra\nsuite\t-\nname\t-\nmessage\t" infra_line; printf "%s", infra_detail; print ""; exit 0
      }
      if (recs == "" && !have_total && !started && passed + failed == 0) {
        print "counts\t0\t0\t" raw; print "kind\tunreadable\nsuite\t-\nname\t-\nmessage\trunner output not recognised\n"; exit 0
      }
      if (recs == "" && !in_failures) for (i = 1; i <= nlist; i++)
        recs = recs "kind\ttest\nsuite\t" (list_suite[i] == "" ? "-" : list_suite[i]) "\nname\t" list_name[i] "\nmessage\t-\n\n"
      print "counts\t" passed "\t" failed "\t" raw
      printf "%s", recs
    }' "$_fp_tmp"
  _fp_rc=$?
  rm -f "$_fp_tmp"
  return $_fp_rc
}

# dsh_render_feedback <selector> <logpath>: the record stream (stdin) -> the block the agent reads.
# Only records reach the agent: never a raw line. Suite names are shortened to their last segment.
# A six-field counts row (the scalafix/scalac adapters) heads the block `FEEDBACK: E errors, W
# warnings (sel)`; a `diagnostic` record renders `DIAGNOSTIC: file [code] message`, its detail rows,
# then `  INSTRUCTION: …` and `  DOC: …` when dsh_instructions_annotate found them. Every code that
# reached the renderer without an instruction is named once in `No instruction for: a, b` before
# the `Raw output …` line, so a gap in the table is visible to the human, never silent.
dsh_render_feedback() {
  awk -F'\t' -v sel="${1:-}" -v logpath="${2:-}" '
    BEGIN { na = 0; nd = 0; any = 0 }
    function short(s, n, seg) { n = split(s, seg, "."); return (n > 0 ? seg[n] : s) }
    function emit() {
      if (kind == "") return
      pre = (draft == "1") ? "DRAFT " : ""
      if (kind == "infra") { print "INFRA: " msg; for (i = 1; i <= nd; i++) print "  " det[i]; keep = 1 }
      else if (kind == "unreadable") { print "UNREADABLE: " msg; keep = 1 }
      else if (kind == "diagnostic") {
        print "DIAGNOSTIC: " file " [" code "] " msg
        for (i = 1; i <= nd; i++) print "  " det[i]
        if (instr != "") print "  INSTRUCTION: " instr
        if (doc != "") print "  DOC: " doc
        if (instr == "" && !(code in gap)) { gap[code] = 1; gaps = gaps (gaps == "" ? "" : ", ") code }
      }
      else {
        print pre (kind == "property" ? "PROPERTY: " : "TEST: ") (suite == "-" ? "" : short(suite) ".") name
        for (i = 0; i < na; i++) {
          if (lbl[i] ~ /_ORIGINAL$/) continue
          line = "  " lbl[i] ": " val[i]
          o = lbl[i] "_ORIGINAL"; if ((o in byl) && byl[o] != val[i]) line = line " (shrunk from " byl[o] ")"
          print line
        }
        print "  FAILURE: " msg
      }
      kind = ""; draft = ""; suite = ""; name = ""; msg = ""; na = 0; nd = 0; split("", byl); split("", lbl); split("", val); split("", det)
      code = ""; file = ""; instr = ""; doc = ""
    }
    $1 == "counts" { raw = $4
      if (NF >= 6) printf "FEEDBACK: %s errors, %s warnings (%s)\n", $5, $6, sel
      else printf "FEEDBACK: %s passed, %s failed (%s)\n", $2, $3, sel; next }
    $1 == "kind" { emit(); kind = $2; any = 1; next }
    $1 == "draft" { draft = $2; next }
    $1 == "suite" { suite = substr($0, length($1) + 2); next }
    $1 == "name" { name = substr($0, length($1) + 2); next }
    $1 == "arg" { lbl[na] = $2; val[na] = substr($0, length($1) + length($2) + 3); byl[$2] = val[na]; na++; next }
    $1 == "message" { msg = substr($0, length($1) + 2); next }
    $1 == "detail" { det[++nd] = substr($0, length($1) + 2); next }
    $1 == "code" { code = substr($0, length($1) + 2); next }
    $1 == "file" { file = substr($0, length($1) + 2); next }
    $1 == "instruction" { instr = substr($0, length($1) + 2); next }
    $1 == "doc" { doc = substr($0, length($1) + 2); next }
    END { emit()
      if (gaps != "") print "No instruction for: " gaps
      if (any && raw != "") print (keep ? "Raw output kept: " : "Raw output suppressed: ") raw " lines — " logpath }'
}

# dsh_instruction_for <code> [root]: the instruction and doc for a finding code, from the two frozen
# tables under .dsh/instructions/ -- local.tsv (project-owned: scalac kinds, warts, project rules)
# first, then purrism.tsv (vendored by .dsh/engine/instructions-sync.sh). An exact code match wins; failing
# that, a row whose KIND (the text after the last `.`) equals the code's kind answers, because a
# purrism finding prints under the name of the rule that emitted it (`TypelevelPurrism.<kind>`, a
# deprecated alias such as `PreferHKTTypeclasses.<kind>`) while the catalog lists it under its home
# rule -- kinds are unique across the catalog, so the join is safe. Prints `<instruction> TAB <doc>`
# and returns 0, or nothing and 1. A row that is not six TAB fields is skipped, never fatal. Only
# the tables that exist are read: BSD awk aborts on the first unreadable file, so a missing
# local.tsv (check-harness rule 3 FAILs it, but the lookup runs first) must not hide every purrism row.
dsh_instruction_for() {
  _if_code=${1:-}; _if_root=${2:-$(gate_root)}
  [ -n "$_if_code" ] || return 1
  _if_dir="$_if_root/.dsh/instructions"
  set -- ; for _if_t in local purrism; do [ -f "$_if_dir/$_if_t.tsv" ] && set -- "$@" "$_if_dir/$_if_t.tsv"; done
  [ $# -gt 0 ] || return 1
  _if_out=$(awk -F'\t' -v code="$_if_code" '
    BEGIN { kind = code; sub(/^.*\./, "", kind); exact = ""; bykind = "" }
    /^#/ || NF != 6 { next }
    {
      k = $1; sub(/^.*\./, "", k)
      if ($1 == code && exact == "") { exact = $5 "\t" $6 }
      else if (k == kind && bykind == "") { bykind = $5 "\t" $6 }
    }
    END { if (exact != "") print exact; else if (bykind != "") print bykind }
  ' "$@" 2>/dev/null)
  [ -n "$_if_out" ] || return 1
  printf '%s\n' "$_if_out"
}

# dsh_purrism_declared_version [root]: the scala-purrism-scalafix_3 version buildKit/Layer.mill
# declares (`mvn"io.github.mercurievv:scala-purrism-scalafix_3:<version>"`, the first such literal),
# printed; nothing and 1 when the file or the literal is absent. The ONE reading of that literal:
# instructions-sync.sh (which fetches the jar for it) and check-harness rule 2 (which compares the
# vendored table's header against it) had the same sed each, and a drift between them would let the
# sync write a table the check then calls stale.
dsh_purrism_declared_version() {
  _pv=$(sed -n 's/.*scala-purrism-scalafix_3:\([^"]*\)".*/\1/p' "${1:-$(gate_root)}/buildKit/Layer.mill" 2>/dev/null | head -1)
  [ -n "$_pv" ] || return 1
  printf '%s\n' "$_pv"
}

# dsh_instructions_annotate [root] [missing-file]: a filter over the record stream. After every
# `code` row of a diagnostic record it inserts the `instruction` and `doc` rows dsh_instruction_for
# finds (each only when non-empty); a code with no row is appended ONCE to <missing-file> (the
# human's backlog of instructions to write, .dsh/.state/instructions-missing) and left bare -- the
# renderer names the gap. The hit is split on its LAST TAB: an instruction never holds a TAB (the
# tables are six TAB fields), a doc URL never does either, so the split is exact.
dsh_instructions_annotate() {
  _ia_root=${1:-$(gate_root)}; _ia_missing=${2:-}
  _ia_tab=$(printf '\t')
  while IFS= read -r _ia_line || [ -n "$_ia_line" ]; do
    printf '%s\n' "$_ia_line"
    case "$_ia_line" in
      "code$_ia_tab"*)
        _ia_code=${_ia_line#code"$_ia_tab"}
        if _ia_hit=$(dsh_instruction_for "$_ia_code" "$_ia_root"); then
          _ia_instr=${_ia_hit%"$_ia_tab"*}; _ia_doc=${_ia_hit##*"$_ia_tab"}
          [ -n "$_ia_instr" ] && printf 'instruction\t%s\n' "$_ia_instr"
          [ -n "$_ia_doc" ] && printf 'doc\t%s\n' "$_ia_doc"
        elif [ -n "$_ia_missing" ]; then
          if ! grep -qxF -- "$_ia_code" "$_ia_missing" 2>/dev/null; then printf '%s\n' "$_ia_code" >> "$_ia_missing"; fi
        fi ;;
    esac
  done
}

# dsh_bash_action_paths <command>: one `<kind>` TAB `<token>` row per path a bash command names as
# an ACTION rather than as a read, in the order the command names them:
#
#   write  the DESTINATION the command writes: a redirection target (`>`/`>>`/`2>`, with a quoted
#          or unquoted spelling either way), `tee`'s file arguments, the files `sed -i` edits, the
#          destination of cp/mv/install/rsync (including -t/--target-directory, read for the three
#          that mean it -- `rsync -t` is --times) and `dd`'s `of=`;
#   cd     the directory a `cd`/`pushd` selects.
#
# It is the ONE extractor behind both frozen-path rules on the bash route -- the write verdict
# (semantic-guard) and the operand verdict (tool-policy) -- so the two cannot disagree about which
# spelling of a command writes what.
#
# Text-matching, like every other verdict in this harness, and it inherits the documented limits: a
# path built by a variable, a function or a loop is not resolved. Two readings it DOES make, both
# deliberate: a `\`-continued command is joined, so `cp <source> \` + newline + `<dest>` decides on
# the destination; and a shell comment (a `#` at the start of a word) ends the line, so
# `cp /tmp/x dest  # draft` and `rsync … dest --exclude foo` still decide on `dest` -- the
# destination is the last OPERAND, and an option's own argument (`--exclude foo`, `-m 755`) is not
# one. Quoting is punctuation: `> "dest"` names the same destination as `> dest`.
dsh_bash_action_paths() { # <command text>
  printf '%s' "${1:-}" | awk '
    function wflush() { if (tok != "") { nt++; tt[nt] = "W"; tv[nt] = tok; tok = "" } }
    function oflush() { if (op != "") { nt++; tt[nt] = "O"; tv[nt] = op; op = "" } }
    function endl() { oflush(); wflush(); nt++; tt[nt] = "N"; tv[nt] = "" }
    function emit(k, v) { if (v == "") return; key = k "\t" v; if (!(key in seen)) { seen[key] = 1; rows++; rk[rows] = k; rv[rows] = v } }
    function endcmd(   j, base, has_t, has_i, last, a) {
      if (cw == "") { na = 0; return }
      base = cw; sub(/^.*\//, "", base)
      if (base == "cp" || base == "mv" || base == "install" || base == "rsync") {
        has_t = 0
        for (j = 1; j <= na; j++) {
          a = args[j]
          if (base != "rsync" && (a == "-t" || a == "--target-directory")) {
            if (j < na) { emit("write", args[j + 1]); has_t = 1 }
            continue
          }
          if (base != "rsync" && a ~ /^--target-directory=/) { emit("write", substr(a, 20)); has_t = 1; continue }
          if (base != "rsync" && a ~ /^-t./) { emit("write", substr(a, 3)); has_t = 1; continue }
        }
        if (has_t == 0) {
          # The DESTINATION is the last operand -- and, because an option can sit BETWEEN a source
          # and its destination (`cp /tmp/x -f dest`, `rsync /tmp/x -a dest`), every other operand
          # that is not immediately preceded by an option as well. The FIRST operand is never one:
          # it is the source, which the command READS (`cp <frozen> /tmp/backup` stays allowed).
          #
          # What this cannot tell apart is the value of an option when it comes after the first
          # operand (`rsync -a /tmp/x dest --exclude foo` names `foo`; a frozen `foo` would be
          # refused). Text-matching, in the safe direction, and the documented way out is to spell
          # the destination unambiguously or to operate on one path at a time.
          nops = 0
          lastop = 0
          for (j = 1; j <= na; j++) if (args[j] !~ /^-/) { nops++; lastop = j }
          nops = 0
          for (j = 1; j <= na; j++) {
            if (args[j] ~ /^-/) continue
            nops++
            if (nops == 1) continue
            if (j == lastop) { emit("write", args[j]); continue }
            if (j > 1 && args[j - 1] ~ /^-/) continue
            emit("write", args[j])
          }
        }
      } else if (base == "dd") {
        for (j = 1; j <= na; j++) if (args[j] ~ /^of=/) emit("write", substr(args[j], 4))
      } else if (base == "tee") {
        for (j = 1; j <= na; j++) if (args[j] !~ /^-/) emit("write", args[j])
      } else if (base == "sed") {
        has_i = 0
        for (j = 1; j <= na; j++) if (args[j] ~ /^-i/) has_i = 1
        if (has_i) for (j = 1; j <= na; j++) if (args[j] !~ /^-/) emit("write", args[j])
      } else if (base == "cd" || base == "pushd") {
        found = 0
        for (j = 1; j <= na; j++) {
          if (args[j] == "-P" || args[j] == "-L" || args[j] == "--") continue
          emit("cd", args[j]); found = 1; break
        }
        # A bare `pushd` swaps with the directory stack -- a base this layer cannot know. A bare
        # `cd` goes to $HOME, which is outside the repository unless the session was booted there.
        if (!found && base == "pushd") emit("cd", "-")
      }
      na = 0
    }
    {
      n = length($0); q = ""; cont = 0; ws = 1
      if (n > 0 && substr($0, n, 1) == "\\") { cont = 1; n = n - 1 }
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (q != "") { if (c == q) { q = ""; ws = 0 } else { tok = tok c }; continue }
        # The pending operator is flushed BEFORE a quoted token opens (and before the line ends):
        # otherwise `> "dest"` emits the word ahead of the operator and the redirect rule, which
        # reads the token before the path, never sees it.
        if (c == "\047" || c == "\042") { oflush(); q = c; ws = 0; continue }
        if (c == "#" && tok == "" && ws == 1) break
        if (c == " " || c == "\t") { wflush(); ws = 1; continue }
        if (index("|;&()<>", c) > 0) { wflush(); op = op c; ws = 1; continue }
        oflush(); tok = tok c; ws = 0
      }
      if (cont) { wflush(); oflush() } else { endl() }
    }
    END {
      wflush(); oflush(); endl()
      cw = ""; na = 0
      for (i = 1; i <= nt; i++) {
        if (tt[i] == "N" || (tt[i] == "O" && tv[i] ~ /[|;&()]/)) { endcmd(); cw = ""; na = 0; continue }
        if (tt[i] == "O") continue
        w = tv[i]
        # A redirection target: the operator right before it carries a `>`, and is not an fd dup
        # (`>&2`, `2>&1` — those end in `&`, and their next word is a descriptor, not a file).
        if (i > 1 && tt[i - 1] == "O" && tv[i - 1] ~ />/ && tv[i - 1] !~ /&$/) emit("write", w)
        if (cw == "") {
          base = w; sub(/^.*\//, "", base)
          if (base == "sudo" || base == "env" || base == "time" || base == "nohup" || base == "command" \
              || base == "exec" || base == "xargs" || base == "do" || base == "then" || base == "else" \
              || base == "if" || base == "while" || base == "until") continue
          cw = w; na = 0
          continue
        }
        args[++na] = w
      }
      endcmd()
      for (i = 1; i <= rows; i++) print rk[i] "\t" rv[i]
    }'
}

# dsh_bash_cd_base <rows> [root]: where a `cd`/`pushd` in the command sends a relative path, as the
# four answers a caller has to tell apart:
#
#   exit 1, no output   no `cd`/`pushd` in the command: a relative path resolves against the root;
#   exit 0, prints the repo-relative directory, for the LAST `cd` whose target is a literal path of
#                       this repository (relative, or absolute under the root) -- a caller resolves
#                       a relative path P against it as `B/P`;
#   exit 3, no output   the last such `cd` provably leaves the repository (an absolute path outside
#                       the root): the BASE adds nothing, and a caller answers a relative path by its
#                       own spelling alone (which is usually "not frozen", since a path under the
#                       root is not where that `cd` went);
#   exit 2, no output   a target this layer CANNOT resolve -- a variable or a command substitution,
#                       a relative path walking out of the root, `cd -` or a bare `pushd`.
#
# With exit 2 a relative path is UNDECIDED and the caller denies it rather than guess a base;
# anything else would be the permissive direction, since `cd engine/details && printf x > notes.md`
# writes the human's module while `notes.md` is not a frozen spelling on its own.
#
# WHAT EXIT 3 DOES NOT MEAN, because the earlier wording read as if it did: it is not "a relative
# path is allowed". The caller asks the ROOT-RELATIVE spelling of every destination FIRST, whatever
# the `cd` says, so `cd /tmp && printf x > engine/details/notes.md` is still refused -- the
# destination, if the `cd` did not take effect, is exactly the frozen file it names, and this layer
# does not decide whether `/tmp` existed. Exit 3 only stops the base from being consulted a second
# time. A `cd` that fails mid-line is the same case from the other side: the relative names in the
# rest of the line are resolved against the root, which is the base the shell itself would still be
# in.
dsh_bash_cd_base() { # <rows> [root]
  _cb_rows=${1:-}
  _cb_root=${2:-$(gate_root)}
  _cb_tab=$(printf '\t')
  _cb_base=''
  _cb_unknown=0
  _cb_outside=0
  # Globbing off around the split: the rows are unquoted (IFS is a newline) and a token may hold a
  # `*`. `$-` is the caller's.
  _cb_noglob=1
  case $- in *f*) _cb_noglob=0 ;; esac
  [ "$_cb_noglob" = 1 ] && set -f
  _cb_ifs=$IFS
  IFS='
'
  for _cb_row in $_cb_rows; do
    IFS=$_cb_ifs
    case "$_cb_row" in
      cd"$_cb_tab"*) ;;
      *) continue ;;
    esac
    _cb_target=${_cb_row#*"$_cb_tab"}
    case "$_cb_target" in
      *'$'*|*'`'*|-)
        _cb_unknown=1
        continue ;;
    esac
    _cb_rel=$(dsh_repo_relpath "$_cb_target" "$_cb_root")
    if [ -n "$_cb_rel" ]; then
      _cb_base=$_cb_rel
      continue
    fi
    case "$_cb_target" in
      /*) _cb_outside=1 ;;   # absolute and outside the root: decidable, nothing under it is frozen
      *) _cb_unknown=1 ;;    # relative and walking out: which way it walks is unknown from here
    esac
  done
  IFS=$_cb_ifs
  [ "$_cb_noglob" = 1 ] && set +f
  if [ -n "$_cb_base" ]; then
    printf '%s\n' "$_cb_base"
    return 0
  fi
  [ "$_cb_unknown" = 1 ] && return 2
  [ "$_cb_outside" = 1 ] && return 3
  return 1
}

deny() { printf '%s\n' "$1" >&2; exit 2; }
allow() { if [ -n "${1:-}" ]; then printf '%s\n' "$1"; fi; exit 0; }

# --- holdout: the installation rules -----------------------------------------------------------------
# dsh_holdout_checks [root]: one `ok|FAIL|note` TAB <message> row per rule; exit 1 when any FAIL.
# check-harness.sh maps the rows onto its ok/bad/note; lib-test.sh drives the function directly.
dsh_holdout_checks() {
  _hc_root=${1:-$(gate_root)}
  _hc_tab=$(printf '\t')
  _hc_bad=0
  _hc_map="$_hc_root/.dsh/.state/modules.tsv"

  # rule 4 first: a list that does not parse cannot be judged by the rules below. The row must stay
  # ONE physical line -- check-harness.sh reads rows with `IFS=tab read`, and a raw embedded newline
  # would surface as a second, unrecognised row -- so the stderr lines are folded with '; ', bounded.
  _hc_err=$(dsh_frozen_paths "$_hc_root" 2>&1 >/dev/null)
  if [ $? != 0 ]; then
    _hc_errline=$(printf '%s' "$_hc_err" | tr '\n' ';' | sed 's/;[ ]*/; /g; s/; *$//')
    _hc_errline=$(printf '%s' "$_hc_errline" | cut -c1-400)
    printf 'FAIL\tfrozen-paths has a malformed entry — the hooks enforce only what parses: %s\n' "$_hc_errline"
    _hc_bad=1
  fi

  # rule 1: every tests-capable module has its test root frozen or sealed. `modules.tsv` may end
  # without a trailing newline; `read` returns non-zero on that final unterminated record and would
  # silently skip it fed straight from `<"$_hc_map"`, so the content is re-fed through a heredoc,
  # which always terminates its last line -- and the loop stays in THIS shell (it sets _hc_unfrozen).
  _hc_unfrozen=''
  if [ -f "$_hc_map" ]; then
    # split tab-exactly: `IFS=tab read` merges consecutive tabs, so an empty-caps four-column row
    # (`x<TAB>x<TAB><TAB>deps`) would read its dependents as the capabilities.
    while IFS= read -r _hc_row; do
      _hc_dir=${_hc_row%%"$_hc_tab"*}
      _hc_rest=${_hc_row#*"$_hc_tab"}
      [ "$_hc_rest" != "$_hc_row" ] || continue
      _hc_mod=${_hc_rest%%"$_hc_tab"*}
      _hc_caps=''
      case "$_hc_rest" in *"$_hc_tab"*) _hc_caps=${_hc_rest#*"$_hc_tab"}; _hc_caps=${_hc_caps%%"$_hc_tab"*} ;; esac
      [ -n "$_hc_mod" ] || continue
      case ",$_hc_caps," in *,tests,*) ;; *) continue ;; esac
      _hc_probe="$_hc_dir/test/.probe"; [ "$_hc_dir" = . ] && _hc_probe="test/.probe"
      dsh_frozen_reason "$_hc_probe" "$_hc_root" >/dev/null || _hc_unfrozen="$_hc_unfrozen $_hc_mod"
    done <<EOF
$(cat "$_hc_map")
EOF
  fi
  if [ ! -f "$_hc_map" ]; then
    printf 'note\tno coverage map at .dsh/.state/modules.tsv — test-root freezes could not be checked; run the contract'"'"'s coverage command (./mill moduleMap) and re-run this check\n'
  elif [ -n "$_hc_unfrozen" ]; then
    printf 'FAIL\ttest roots not frozen — the agent could edit the tests it is judged by:%s (add `<dir>/test/**` with a reason to .dsh/frozen-paths)\n' "$_hc_unfrozen"; _hc_bad=1
  else
    printf 'ok\tevery module the coverage map marks `tests` has its test root frozen or sealed\n'
  fi

  # rules 5 and 2: the holdout line, and a seal on its target
  _hc_cmd=$(dsh_contract_get holdout "$_hc_root" 2>/dev/null) || _hc_cmd=''
  _hc_target=holdout
  if [ -z "$_hc_cmd" ]; then
    printf 'note\t.dsh/contract has no `holdout =` line — the gate runs no held-out suite at turn-end; the project is legal but weaker (spec §2)\n'
  else
    # the Mill selector is the command's last word; its module dir is the first dotted segment
    _hc_sel=${_hc_cmd##* }
    _hc_target=${_hc_sel%%.*}
    [ -n "$_hc_target" ] || _hc_target=holdout
    if [ "$(dsh_frozen_access "$_hc_target/.probe" "$_hc_root" 2>/dev/null)" = sealed ]; then
      printf 'ok\tthe holdout target %s/** is sealed (reads and writes denied)\n' "$_hc_target"
    else
      printf 'FAIL\tthe holdout target %s/** is not sealed — add `sealed<TAB>%s/**<TAB><reason>` to .dsh/frozen-paths; a holdout suite the agent can read is one it can special-case\n' "$_hc_target" "$_hc_target"; _hc_bad=1
    fi
  fi

  # rule 3: the harness protects itself -- its own files, the ripgrep ignore file that keeps sealed
  # paths out of Grep, the hook wiring Claude Code actually reads, and the two state files the gate
  # writes and the agent must not (the receipts record, the coverage map cache).
  _hc_missing=''
  for _hc_p in .dsh/frozen-paths .dsh/contract .dsh/hooks.json .dsh/engine/gate.sh .dsh/engine/lib.sh .dsh/engine/hooks/.probe .dsh/engine/check-harness.sh \
               .ignore .claude/settings.json .claude/settings.local.json .dsh/cc-settings.json \
               .dsh/.state/receipts .dsh/.state/modules.tsv; do
    dsh_frozen_reason "$_hc_p" "$_hc_root" >/dev/null || _hc_missing="$_hc_missing ${_hc_p%/.probe}"
  done
  if [ -n "$_hc_missing" ]; then
    printf 'FAIL\tharness files not frozen — an agent could edit the freeze list itself:%s\n' "$_hc_missing"; _hc_bad=1
  else
    printf 'ok\tthe harness self-freeze is complete (frozen-paths, contract, hooks.json, engine/gate.sh, engine/lib.sh, engine/hooks/**, engine/check-harness.sh, .ignore, .claude/settings.json, .claude/settings.local.json, cc-settings.json, .state/receipts, .state/modules.tsv)\n'
  fi

  # rule 6: the holdout module is not in preCommit's aggregates
  if [ -f "$_hc_map" ]; then
    _hc_row=$(awk -F"$_hc_tab" -v d="$_hc_target" '$1 == d { print $3; found = 1; exit } END { if (!found) print "<none>" }' "$_hc_map")
    case ",$_hc_row," in
      *,tests,*|*,fmt,*)
        printf 'FAIL\tthe holdout module %s carries capabilities (%s) — it is reachable from preCommit, so the agent could run it and read the failure text; keep it out of mainModules and testCompileModules\n' "$_hc_target" "$_hc_row"; _hc_bad=1 ;;
      *) printf 'ok\tthe holdout module %s is not in preCommit'"'"'s aggregates (capabilities: %s)\n' "$_hc_target" "$_hc_row" ;;
    esac
  fi
  [ "$_hc_bad" = 0 ]
}

# --- the module map's dependents column (spec 2026-10-01 §4) -------------------------------------------
# dsh_dependents_column_check [root]: one `ok|note` TAB <message> row; always exit 0. No map yet → no
# row (other checks already say how to build it). A map where no row has a fourth field → a note: the
# project's Gate.mill predates the dependents column, so turn-end runs only the touched modules' tests —
# today's behaviour, not a broken gate, hence not a FAIL.
dsh_dependents_column_check() {
  _dc_root=${1:-$(gate_root)}
  _dc_map="$_dc_root/.dsh/.state/modules.tsv"
  [ -s "$_dc_map" ] || return 0
  if awk -F'\t' 'NF >= 4 { f = 1 } END { exit !f }' "$_dc_map"; then
    printf 'ok\tthe module map lists each module'"'"'s dependents, so turn-end runs their tests\n'
  else
    printf 'note\tdownstream tests disabled — the module map has no dependents column; update buildKit/Gate.mill (moduleMapRows) and re-run ./mill moduleMap\n'
  fi
  return 0
}

# --- feedback: the installation rules ------------------------------------------------------------
# dsh_feedback_checks [root] [engine]: one `ok|FAIL|note` TAB <message> row per rule (spec 2026-09-20-property-
# feedback-loop-design §3); exit 1 iff any FAIL. check-harness.sh maps the rows onto ok/bad/note;
# lib-test.sh drives the function directly. Rows stay ONE physical line each.
dsh_feedback_checks() {
  _fc_root=${1:-$(gate_root)}
  # [engine] is the engine whose wrapper is judged; the default is the project's vendored one.
  _fc_engine=${2:-$_fc_root/.dsh/engine}
  _fc_tab=$(printf '\t')
  _fc_bad=0

  # rule 1: the wrapper exists and parses -- prefer dash (the harness's real interpreter), fall
  # back to sh when dash is not installed.
  _fc_wrapper="$_fc_engine/hooks/feedback.sh"
  if [ ! -f "$_fc_wrapper" ]; then
    printf 'FAIL\tthe feedback wrapper is missing: .dsh/engine/hooks/feedback.sh\n'; _fc_bad=1
  else
    if command -v dash >/dev/null 2>&1; then _fc_sh=dash; else _fc_sh=sh; fi
    if "$_fc_sh" -n "$_fc_wrapper" 2>/dev/null; then
      printf 'ok\tthe feedback wrapper .dsh/engine/hooks/feedback.sh exists and parses under `%s -n`\n' "$_fc_sh"
    else
      printf 'FAIL\tthe feedback wrapper .dsh/engine/hooks/feedback.sh does not parse under `%s -n`\n' "$_fc_sh"; _fc_bad=1
    fi
  fi

  # rule 2: a *Props.scala under a tests-capable module's test/src that names neither `forall` nor
  # `Checkers` is not a real property test -- it is a plain test wearing the convention's name.
  _fc_map="$_fc_root/.dsh/.state/modules.tsv"
  _fc_bareprops=''
  _fc_propsfiles=$(dsh_find_pruned "$_fc_root" -path '*/test/src/*' -name '*Props.scala' -print)
  if [ -n "$_fc_propsfiles" ]; then
    while IFS= read -r _fc_f; do
      [ -n "$_fc_f" ] || continue
      _fc_rel=${_fc_f#"$_fc_root"/}
      _fc_dir=${_fc_rel%%/test/src/*}
      _fc_caps=''
      [ -f "$_fc_map" ] && _fc_caps=$(awk -F"$_fc_tab" -v d="$_fc_dir" '$1 == d { print $3 }' "$_fc_map")
      case ",$_fc_caps," in *,tests,*) ;; *) continue ;; esac
      if ! grep -q -E 'forall|Checkers' "$_fc_f" 2>/dev/null; then
        _fc_bareprops="$_fc_bareprops $_fc_rel"
      fi
    done <<EOF
$_fc_propsfiles
EOF
  fi
  if [ -n "$_fc_bareprops" ]; then
    printf 'FAIL\t*Props.scala files that name neither `forall` nor `Checkers` (not a real property test):%s\n' "$_fc_bareprops"; _fc_bad=1
  elif [ ! -f "$_fc_map" ]; then
    # Without the map no module is known to be `tests`, so no file was judged: that is a note, as the
    # holdout rule 1 says of the same absence -- never an `ok` earned by checking nothing.
    printf 'note\tno coverage map at .dsh/.state/modules.tsv — *Props.scala files could not be checked for `forall`/`Checkers`; run the contract'"'"'s coverage command (./mill moduleMap) and re-run this check\n'
  else
    printf 'ok\tevery *Props.scala under a tests module'"'"'s test/src names `forall` or `Checkers`\n'
  fi

  # rule 3: the two contract keys the feedback loop needs
  for _fc_key in fastTests turnEndTests; do
    _fc_val=$(dsh_contract_get "$_fc_key" "$_fc_root" 2>/dev/null) || _fc_val=''
    if [ -n "$_fc_val" ]; then
      printf 'ok\tthe contract has a `%s =` line\n' "$_fc_key"
    else
      printf 'note\t.dsh/contract has no `%s =` line — the corresponding stage of the feedback loop (spec §2) does not run\n' "$_fc_key"
    fi
  done

  # rule 4: unpromoted drafts -- an agent forgot a `git mv`, or is mid-shrink on one
  _fc_drafts=$(dsh_find_pruned "$_fc_root" -path '*/test-draft/src/*' -type f -print)
  if [ -n "$_fc_drafts" ]; then
    _fc_draftlist=$(printf '%s\n' "$_fc_drafts" | sed "s|^$_fc_root/||" | tr '\n' ' ' | sed 's/ $//')
    printf 'note\tfiles await promotion under test-draft/src:%s\n' " $_fc_draftlist"
  else
    printf 'ok\tno files sit under test-draft/src — nothing awaits promotion\n'
  fi

  # rule 5: the feedback log directory should stay bounded (the wrapper prunes to 20 on its next run)
  _fc_logdir="$_fc_root/.dsh/.state/feedback"
  _fc_nlogs=0
  [ -d "$_fc_logdir" ] && _fc_nlogs=$(find "$_fc_logdir" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$_fc_nlogs" -gt 20 ] 2>/dev/null; then
    printf 'note\t%s feedback logs under .dsh/.state/feedback/ (more than 20) — the wrapper prunes to the newest 20 on its next run\n' "$_fc_nlogs"
  else
    printf 'ok\t%s feedback log(s) under .dsh/.state/feedback/ (20 or fewer)\n' "$_fc_nlogs"
  fi

  [ "$_fc_bad" = 0 ]
}

# dsh_instruction_checks [root]: the instruction-table installation rules (spec 2026-09-20
# diagnostic→instruction §3), one `ok|FAIL|note` TAB <message> row per rule; exit 1 iff any FAIL.
# check-harness.sh maps the rows onto ok/bad/note; lib-test.sh drives the function directly.
#   1 purrism.tsv present, header `# purrism <v>`, every row six TAB fields, codes unique
#   2 that <v> equals the scala-purrism-scalafix_3 version buildKit/Layer.mill declares
#   3 local.tsv parseable, every code `<rule>.<kind>` (scalac.<kebab>, wartremover.<Wart>,
#     scalafix.<kebab> or <Rule>.<kebab>); scalac-kinds.tsv rows `kind TAB regex`, every kind
#     backed by a `scalac.<kind>` row in local.tsv
#   4 note: the codes in .dsh/.state/instructions-missing (instructions the human has yet to write)
#   5 purrism.tsv, local.tsv, scalac-kinds.tsv and instructions-sync.sh are frozen
# Rows stay ONE physical line each.
dsh_instruction_checks() {
  _ic_root=${1:-$(gate_root)}; _ic_dir="$_ic_root/.dsh/instructions"; _ic_bad=0

  # rule 1: the vendored purrism table
  _ic_p="$_ic_dir/purrism.tsv"; _ic_pv=''
  if [ ! -f "$_ic_p" ]; then
    printf 'FAIL\t.dsh/instructions/purrism.tsv is missing — run `sh .dsh/engine/instructions-sync.sh`\n'; _ic_bad=1
  else
    _ic_pv=$(sed -n '1s/^# purrism \(.*\)$/\1/p' "$_ic_p")
    _ic_nf=$(awk -F'\t' 'NR > 1 && NF && NF != 6 { n++ } END { print n + 0 }' "$_ic_p")
    _ic_dup=$(awk -F'\t' 'NR > 1 && NF == 6 { print $1 }' "$_ic_p" | sort | uniq -d | head -3 | tr '\n' ' ')
    if [ -z "$_ic_pv" ]; then
      printf 'FAIL\t.dsh/instructions/purrism.tsv has no `# purrism <version>` header\n'; _ic_bad=1
    elif [ "$_ic_nf" != 0 ]; then
      printf 'FAIL\t.dsh/instructions/purrism.tsv: %s row(s) are not six TAB fields\n' "$_ic_nf"; _ic_bad=1
    elif [ -n "$_ic_dup" ]; then
      printf 'FAIL\t.dsh/instructions/purrism.tsv: duplicate code(s): %s\n' "$_ic_dup"; _ic_bad=1
    else
      printf 'ok\t.dsh/instructions/purrism.tsv parses (purrism %s, %s codes)\n' "$_ic_pv" "$(awk -F'\t' 'NR > 1 && NF == 6' "$_ic_p" | wc -l | tr -d ' ')"
    fi
  fi

  # rule 2: the table's version is the one the build declares
  _ic_bv=$(dsh_purrism_declared_version "$_ic_root") || _ic_bv=''
  if [ -n "$_ic_pv" ] && [ -n "$_ic_bv" ]; then
    if [ "$_ic_pv" = "$_ic_bv" ]; then
      printf 'ok\tpurrism.tsv (%s) matches the version buildKit/Layer.mill declares\n' "$_ic_pv"
    else
      printf 'FAIL\tpurrism.tsv is for purrism %s but buildKit/Layer.mill declares %s — run `sh .dsh/engine/instructions-sync.sh`\n' "$_ic_pv" "$_ic_bv"; _ic_bad=1
    fi
  elif [ -z "$_ic_bv" ]; then
    printf 'note\tbuildKit/Layer.mill declares no scala-purrism-scalafix_3 version — the table version cannot be checked\n'
  fi

  # rule 3: the project's own table and the scalac kind table
  _ic_l="$_ic_dir/local.tsv"
  if [ ! -f "$_ic_l" ]; then
    printf 'FAIL\t.dsh/instructions/local.tsv is missing (an empty table is `# local` alone)\n'; _ic_bad=1
  else
    _ic_lbad=$(awk -F'\t' 'NR > 1 && NF && !/^#/ { if (NF != 6 || ($1 !~ /^[A-Za-z][A-Za-z0-9]*\.[a-z0-9]+(-[a-z0-9]+)*$/ && $1 !~ /^wartremover\.[A-Za-z0-9]+$/)) print $1 }' "$_ic_l" | head -3 | tr '\n' ' ')
    if [ -n "$_ic_lbad" ]; then
      printf 'FAIL\t.dsh/instructions/local.tsv: malformed row(s) (six TAB fields, code `<rule>.<kind>`): %s\n' "$_ic_lbad"; _ic_bad=1
    else
      printf 'ok\t.dsh/instructions/local.tsv parses\n'
    fi
    _ic_k="$_ic_dir/scalac-kinds.tsv"
    if [ -f "$_ic_k" ]; then
      _ic_kbad=$(awk -F'\t' -v l="$_ic_l" 'BEGIN { while ((getline r < l) > 0) { split(r, f, "\t"); if (f[1] ~ /^scalac\./) { c = f[1]; sub(/^scalac\./, "", c); have[c] = 1 } } }
        /^#/ || !NF { next } { if (NF != 2 || !($1 in have)) print $1 }' "$_ic_k" | head -3 | tr '\n' ' ')
      if [ -n "$_ic_kbad" ]; then
        printf 'FAIL\t.dsh/instructions/scalac-kinds.tsv: kind(s) not `kind TAB regex` or without a scalac.<kind> row in local.tsv: %s\n' "$_ic_kbad"; _ic_bad=1
      else
        printf 'ok\t.dsh/instructions/scalac-kinds.tsv parses and every kind has a local.tsv row\n'
      fi
    else
      printf 'note\tno .dsh/instructions/scalac-kinds.tsv — every scalac diagnostic is coded scalac.error / scalac.warning\n'
    fi
  fi

  # rule 4: the human's backlog of instructions to write
  _ic_m="$_ic_root/.dsh/.state/instructions-missing"
  if [ -s "$_ic_m" ]; then
    printf 'note\tcodes seen without an instruction (write rows in local.tsv or upstream): %s\n' "$(sort -u "$_ic_m" | tr '\n' ' ')"
  else
    printf 'ok\tno diagnostic code has gone without an instruction\n'
  fi

  # rule 5: the tables and their one writer are the human's
  _ic_unfrozen=''
  for _ic_f in .dsh/instructions/purrism.tsv .dsh/instructions/local.tsv .dsh/instructions/scalac-kinds.tsv .dsh/engine/instructions-sync.sh; do
    [ -n "$(dsh_frozen_reason "$_ic_f" "$_ic_root" 2>/dev/null)" ] || _ic_unfrozen="$_ic_unfrozen $_ic_f"
  done
  if [ -n "$_ic_unfrozen" ]; then
    printf 'FAIL\tnot frozen (add to .dsh/frozen-paths):%s\n' "$_ic_unfrozen"; _ic_bad=1
  else
    printf 'ok\tthe instruction tables and the sync script are frozen\n'
  fi

  [ "$_ic_bad" = 0 ]
}

# dsh_bounded_probe <secs> <out> <err> <cmd> [args...]: run <cmd> with stdin closed, stdout to <out>
# and stderr to <err>, for at most <secs> seconds. BOUNDED without `timeout`, which is absent on stock
# macOS: the command runs in the background, is polled once a second, and is killed if it is still
# there. Returns 124 when it had to be killed, else 0 -- the command's own status is not what a probe
# asks, its output is. The launcher probes below use it, so a wedged launcher can never hang
# dsh_verify_checks, and with it lib-test.sh and check-harness.sh.
# _dsh_kill_tree <pid>: kill <pid> and its descendants, deepest first (`pgrep -P`, when there is one).
# A wrapper script (./mill, the launcher) runs its JVM as a CHILD; killing only the wrapper left that
# child running past the cap. Without pgrep only <pid> itself is killed, as before.
_dsh_kill_tree() {
  for _kt_c in $(pgrep -P "$1" 2>/dev/null); do _dsh_kill_tree "$_kt_c"; done
  kill "$1" 2>/dev/null
  return 0
}

dsh_bounded_probe() {
  _bp_secs=$1; _bp_out=$2; _bp_err=$3
  shift 3
  "$@" >"$_bp_out" 2>"$_bp_err" </dev/null &
  _bp_pid=$!
  _bp_n=0
  while [ "$_bp_n" -lt "$_bp_secs" ]; do
    kill -0 "$_bp_pid" 2>/dev/null || break
    sleep 1
    _bp_n=$((_bp_n + 1))
  done
  _bp_rc=0
  if kill -0 "$_bp_pid" 2>/dev/null; then
    _bp_rc=124
    _dsh_kill_tree "$_bp_pid"
  fi
  wait "$_bp_pid" 2>/dev/null
  return "$_bp_rc"
}

# --- diff-scoped verification: the installation rules (spec 2026-09-24 §3) ----------------------
# dsh_verify_checks [root] [engine]: one `ok|FAIL|note` TAB <message> row per rule; exit 1 when any FAIL.
# check-harness.sh maps the rows onto its ok/bad/note; lib-test.sh drives the function directly —
# the same shape as dsh_holdout_checks, dsh_feedback_checks and dsh_instruction_checks.
dsh_verify_checks() {
  _vk_root=${1:-$(gate_root)}
  # [engine] is the engine whose verify-diff.sh is judged; the default is the project's vendored one.
  _vk_engine=${2:-$_vk_root/.dsh/engine}
  _vk_tab=$(printf '\t')
  _vk_bad=0

  # rule 1: the gate itself
  if [ ! -f "$_vk_engine/verify-diff.sh" ]; then
    printf 'FAIL\t.dsh/engine/verify-diff.sh is missing — the turn-end gate calls it and would note instead of checking\n'; _vk_bad=1
  elif [ ! -x "$_vk_engine/verify-diff.sh" ]; then
    printf 'FAIL\t.dsh/engine/verify-diff.sh is not executable\n'; _vk_bad=1
  else
    printf 'ok\t.dsh/engine/verify-diff.sh is present and executable\n'
  fi

  # rule 2: the policy table parses, when there is one
  _vk_p="$_vk_root/.dsh/policy/allowed-types.tsv"
  if [ ! -f "$_vk_p" ]; then
    printf 'note\tno .dsh/policy/allowed-types.tsv — no module has a symbol policy, and none is enforced\n'
  else
    _vk_nf=$(awk -F"$_vk_tab" '!/^#/ && NF { if (NF != 3) n++ } END { print n + 0 }' "$_vk_p")
    if [ "$_vk_nf" != 0 ]; then
      printf 'FAIL\t.dsh/policy/allowed-types.tsv: %s row(s) are not three TAB fields (module dir, prefix, reason)\n' "$_vk_nf"; _vk_bad=1
    else
      _vk_rows=$(awk -F"$_vk_tab" '!/^#/ && NF == 3' "$_vk_p" | wc -l | tr -d ' ')
      if [ "$_vk_rows" = 0 ]; then
        # The same state as no file at all -- no module has a symbol policy and none is enforced --
        # so it gets the same verdict. `ok ... (0 rule row(s))` read as "a policy is enforced".
        printf 'note\t.dsh/policy/allowed-types.tsv has no rule rows — no module has a symbol policy, and none is enforced\n'
      else
        printf 'ok\t.dsh/policy/allowed-types.tsv parses (%s rule row(s))\n' "$_vk_rows"
      fi
    fi
  fi

  # rule 3: the gate and the policy are the human's
  _vk_unfrozen=''
  for _vk_f in .dsh/engine/verify-diff.sh .dsh/policy/allowed-types.tsv; do
    [ -e "$_vk_root/$_vk_f" ] || continue
    [ -n "$(dsh_frozen_reason "$_vk_f" "$_vk_root" 2>/dev/null)" ] || _vk_unfrozen="$_vk_unfrozen $_vk_f"
  done
  if [ -n "$_vk_unfrozen" ]; then
    printf 'FAIL\tnot frozen (add to .dsh/frozen-paths):%s\n' "$_vk_unfrozen"; _vk_bad=1
  else
    printf 'ok\tthe verification gate and its policy table are frozen\n'
  fi

  # rule 4: what the gate can actually reach on this machine -- two INDEPENDENT facts, reported
  # independently. The launcher probe used to sit behind the classpath test, so a machine with a stale
  # jar AND no classpath (the very machine that motivated the probe) never ran it.
  _vk_l=${SCALASEMANTIC_MCP_LAUNCHER:-}
  [ -n "$_vk_l" ] || _vk_l=$(command -v scalasemantic-mcp 2>/dev/null) || _vk_l=''
  if [ -z "$_vk_l" ] || [ ! -x "$_vk_l" ]; then
    printf 'note\tno scalasemantic-mcp launcher on PATH — the semantic half of the gate will note instead of checking\n'
  else
    # A launcher that is present but predates the one-shot `call` subcommand is the exact
    # configuration that produced this gate's silent pass: `call` falls through to `serve`, reads EOF
    # on the closed stdin and exits 0 printing NOTHING on stdout. `-x` alone cannot tell that apart
    # from a healthy launcher, so ask it.
    #
    # The probe sends an empty `files` list, which a CURRENT launcher REJECTS -- measured: rc 1, EMPTY
    # stdout, and `resolve_references failed: ... files must hold at least one ...` on STDERR. So
    # stdout alone cannot be the test (keying on it reported every current launcher as stale), and
    # "any stderr" cannot be either: both a stale and a current jar print the JVM's own `WARNING:
    # ... sun.misc.Unsafe` lines there. What only a launcher with `call` produces is output on stdout
    # OR a stderr line naming `resolve_references`.
    #
    # BOUNDED without depending on `timeout`, which is absent on stock macOS. An uncapped probe would
    # hang this function, and with it `lib-test.sh` and `check-harness.sh`, on exactly the wedged
    # launcher it exists to detect. So: run it in the background, poll for at most 20 s, and kill it
    # if it is still there (dsh_bounded_probe). A probe that had to be killed is its own note --
    # never silence, never ok.
    _vk_out=$(mktemp 2>/dev/null) || _vk_out=${TMPDIR:-/tmp}/dsh-vk.$$
    _vk_err=$(mktemp 2>/dev/null) || _vk_err=${TMPDIR:-/tmp}/dsh-vk-err.$$
    _vk_hung=0
    dsh_bounded_probe 20 "$_vk_out" "$_vk_err" "$_vk_l" call resolve_references '{"files":[]}' "$_vk_root" || _vk_hung=1
    _vk_probe=$(cat "$_vk_out" 2>/dev/null)
    _vk_knows=0
    [ -n "$_vk_probe" ] && _vk_knows=1
    grep -q 'resolve_references' "$_vk_err" 2>/dev/null && _vk_knows=1
    if [ "$_vk_hung" = 1 ]; then
      printf 'note\tthe launcher at %s did not answer `call resolve_references` within 20 s and was killed — the semantic half of the gate will hang or NOTE instead of checking; check the launcher\n' "$_vk_l"
    elif [ "$_vk_knows" = 0 ]; then
      printf 'note\tthe launcher at %s answers nothing to `call resolve_references` — it is probably older than the one-shot `call` mode, and the semantic half of the gate will NOTE every Scala file instead of checking it; reinstall scalasemantic-mcp from a build that has `call` (`./mill installLocal` in ScalaSemanticMCP)\n' "$_vk_l"
    else
      printf 'ok\tthe launcher answers `call resolve_references`\n'
    fi

    # The memorisation check's own call. `literal_tokens` is a separate tool: a launcher can have
    # `call` and still predate it (it then prints `unknown tool: literal_tokens` on stderr and nothing
    # on stdout). So the probe asks a REAL question -- a one-file request carrying its own `source`,
    # which needs neither a file on disk nor the presentation compiler (measured: ~0.5 s) -- and is ok
    # only when the answer carries the probe's own literal back. An empty, echoing or error answer is
    # a note, as is a probe that had to be killed.
    _vk_hung=0
    dsh_bounded_probe 20 "$_vk_out" "$_vk_err" "$_vk_l" call literal_tokens \
      '{"files":[{"uri":"DshLiteralProbe.scala","source":"object DshLiteralProbe { val probe = \"dsh-literal-probe\" }"}]}' \
      "$_vk_root" || _vk_hung=1
    if [ "$_vk_hung" = 1 ]; then
      printf 'note\tthe launcher at %s did not answer `call literal_tokens` within 20 s and was killed — the memorisation check will NOTE instead of checking; check the launcher\n' "$_vk_l"
    elif grep -q '"value" *: *"dsh-literal-probe"' "$_vk_out" 2>/dev/null; then
      printf 'ok\tthe launcher answers `call literal_tokens`\n'
    else
      _vk_why=$(grep -v '^WARNING:' "$_vk_err" 2>/dev/null | head -n 1)
      [ -n "$_vk_why" ] || _vk_why=$(head -n 1 "$_vk_out" 2>/dev/null)
      [ -n "$_vk_why" ] || _vk_why='no output at all'
      printf 'note\tthe launcher at %s does not answer `call literal_tokens` with the literal of a one-file source request (%s) — the memorisation check will NOTE instead of checking; reinstall scalasemantic-mcp from a build that has literal_tokens (`./mill installLocal` in ScalaSemanticMCP)\n' "$_vk_l" "$_vk_why"
    fi
    rm -f "$_vk_out" "$_vk_err" 2>/dev/null
  fi

  # rule 5: the memorisation table (spec 2026-09-25 §3). `dsh_memo_policy` falls back to a default on
  # a malformed threshold so the check keeps working -- which must not stay silent, so every row the
  # readers would skip or misread is a FAIL here, named. The CR of a CRLF-saved table and the blanks
  # around each field are stripped exactly as the readers strip them; a CRLF table alone is a note.
  _vk_m="$_vk_root/.dsh/policy/memorisation.tsv"
  if [ ! -f "$_vk_m" ]; then
    printf 'note\tno .dsh/policy/memorisation.tsv — the memorisation check runs with its defaults (min_overlap 8, min_ratio 0.5, trivial_abs 10) and exempts nothing\n'
  else
    _vk_mr=$(awk -F"$_vk_tab" '
      { if (sub(/\r$/, "")) crlf++ }
      /^#/ || /^[ \t]*$/ { next }
      {
        for (i = 1; i <= NF; i++) { f[i] = $i; gsub(/^ +| +$/, "", f[i]) }
        good = 0; why = ""
        key = (f[1] == "min_overlap" || f[1] == "min_ratio" || f[1] == "trivial_abs")
        if (NF == 2) {
          v = f[2]
          if (key && v ~ /^[0-9.]+$/ && v !~ /\..*\./ && v ~ /[0-9]/) {
            # k/n never exceeds 1, so a min_ratio above 1 flags nothing: the check is silently off.
            if (f[1] == "min_ratio" && v + 0 > 1)
              why = " (min_ratio above 1 would disable the check: k/n is never above 1 -- exempt one construct with an allow row instead)"
            else { good = 1; th++ }
          }
        } else if (NF == 3) {
          # A threshold key with a reason column would read as an exemption for a PATH named after
          # the key, and dsh_memo_policy would silently keep the default.
          if (key)
            why = " (a threshold row takes exactly two fields: this one reads as an exemption for a path named " f[1] " and the default is used)"
          else if (f[1] != "" && f[2] != "" && f[3] != "") { good = 1; ex++ }
        }
        if (!good) {
          nbad++
          if (nbad <= 3) { t = $0; gsub(/\t/, " <TAB> ", t); bad = bad (nbad > 1 ? "; " : "") "line " NR ": " t why }
        }
      }
      END { printf "%d\t%d\t%d\t%d\t%s\n", crlf, th, ex, nbad, bad }' "$_vk_m" 2>/dev/null)
    _vk_crlf=$(printf '%s\n' "$_vk_mr" | cut -f1)
    _vk_th=$(printf '%s\n' "$_vk_mr" | cut -f2)
    _vk_ex=$(printf '%s\n' "$_vk_mr" | cut -f3)
    _vk_nbad=$(printf '%s\n' "$_vk_mr" | cut -f4)
    _vk_badrows=$(printf '%s\n' "$_vk_mr" | cut -f5-)
    case "$_vk_nbad" in
      ''|*[!0-9]*)
        printf 'FAIL\t.dsh/policy/memorisation.tsv could not be read\n'; _vk_bad=1 ;;
      0)
        printf 'ok\t.dsh/policy/memorisation.tsv parses (%s threshold row(s), %s exemption row(s))\n' "$_vk_th" "$_vk_ex" ;;
      *)
        _vk_more=''
        [ "$_vk_nbad" -gt 3 ] && _vk_more=" (and $((_vk_nbad - 3)) more)"
        printf 'FAIL\t.dsh/policy/memorisation.tsv: %s row(s) are neither a threshold (min_overlap, min_ratio or trivial_abs TAB a non-negative decimal) nor an exemption (path TAB construct TAB reason), so the check would silently use a default or ignore them: %s%s\n' \
          "$_vk_nbad" "$_vk_badrows" "$_vk_more"; _vk_bad=1 ;;
    esac
    case "$_vk_crlf" in
      ''|0) ;;
      *) printf 'note\t.dsh/policy/memorisation.tsv has CRLF line endings (%s line(s)) — tolerated, the readers strip the CR, but save it with LF\n' "$_vk_crlf" ;;
    esac
  fi
  # Frozen whether or not the file exists: an agent that could CREATE it could exempt itself.
  if [ -n "$(dsh_frozen_reason .dsh/policy/memorisation.tsv "$_vk_root" 2>/dev/null)" ]; then
    printf 'ok\t.dsh/policy/memorisation.tsv is frozen\n'
  else
    printf 'FAIL\tnot frozen (add to .dsh/frozen-paths): .dsh/policy/memorisation.tsv\n'; _vk_bad=1
  fi

  # The server DISCOVERS its classpath from `.scala-semantic/classpath-<tool>.json` under the workspace
  # root (ScalaSemanticMCP docs/getting-started/integration.md); the harness passes none. Without that
  # metadata the presentation compiler cannot start, and the one-shot call exits 1 for the WHOLE
  # request -- `resolve_references needs the presentation compiler` -- which verify-diff.sh notes.
  _vk_cp=''
  for _vk_c in "$_vk_root"/.scala-semantic/classpath-*.json "$_vk_root"/.scala-semantic/classpath.json; do
    [ -f "$_vk_c" ] && { _vk_cp=$_vk_c; break; }
  done
  if [ -n "$_vk_cp" ]; then
    printf 'ok\tclasspath metadata found (%s), so the presentation compiler can type the changed lines\n' "${_vk_cp#"$_vk_root"/}"
  else
    printf 'note\tno .scala-semantic/classpath-<tool>.json — the presentation compiler cannot start, so every resolve_references call exits 1 and the gate NOTEs instead of checking; generate it with the build'"'"'s scalaSemanticWriteClasspath task\n'
  fi
  if ! command -v cs >/dev/null 2>&1; then
    printf 'note\tno `cs` (coursier) on PATH — an added dependency coordinate will be noted, never resolved\n'
  else
    printf 'ok\t`cs` is on PATH, so an added coordinate is resolved\n'
  fi

  [ "$_vk_bad" = 0 ] || return 1
  return 0
}

# dsh_allow_updated_command <command> <reason>: the PreToolUse JSON that lets the call through with a
# rewritten bash command (Claude Code's `updatedInput`; DSH's hook bridge reads the same shape). Exits 0.
dsh_allow_updated_command() {
  if command -v jq >/dev/null 2>&1; then
    jq -cn --arg c "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$r,updatedInput:{command:$c}}}'
  else
    python3 -c 'import json,sys; print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":sys.argv[2],"updatedInput":{"command":sys.argv[1]}}}))' "$1" "$2"
  fi
  exit 0
}
