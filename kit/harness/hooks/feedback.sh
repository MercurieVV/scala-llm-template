#!/bin/sh
# The feedback wrapper (spec 2026-09-20-property-feedback-loop-design §2): run a test command, keep its
# whole output in .dsh/.state/feedback/<utc>.log, and print only what the agent can act on -- the
# FEEDBACK/PROPERTY/TEST/INFRA block from lib.sh's dsh_feedback_parse + dsh_render_feedback. The
# command's own exit status is returned, so a red run stays red. Usage:
#   sh .dsh/engine/hooks/feedback.sh [--raw] [--adapter auto|weaver|scalacheck|munit|scalafix|scalac] [--selector S] -- <cmd...>
#
# Diagnostics (spec 2026-09-20 diagnostic→instruction §2-3): the scalafix and scalac adapters turn a
# `./mill core.fixStrict` / `core.compile` run into DIAGNOSTIC records; dsh_instructions_annotate
# looks each finding code up in the two tables under .dsh/instructions/ (local.tsv, then the vendored
# purrism.tsv) and the block carries `INSTRUCTION:`/`DOC:` under each finding. A code with no row is
# appended once to .dsh/.state/instructions-missing (the human's backlog) and named in a trailing
# `No instruction for:` line. DSH_FEEDBACK_LOG_OUT=<file>, when set, receives the raw log's absolute
# path, so a caller (the Stop-gate checks) can point at the log without parsing this block.
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/lib.sh"
root=$(gate_root)
raw=0; adapter=auto; selector=''
while [ $# -gt 0 ]; do
  case "$1" in
    --raw) raw=1; shift ;;
    --adapter) adapter=${2:-auto}; shift 2 ;;
    --selector) selector=${2:-}; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { printf 'feedback.sh: no command after --\n' >&2; exit 64; }
if [ -z "$selector" ]; then for w in "$@"; do case "$w" in *.test*|*.compile|*.fix|*.fixStrict) selector=$w ;; esac; done; fi
[ -n "$selector" ] || selector=$1
dir="$(state_dir)/feedback"; mkdir -p "$dir" 2>/dev/null
stamp=$(date -u '+%Y-%m-%dT%H-%M-%SZ'); log="$dir/$stamp.log"; n=1
while [ -e "$log" ]; do log="$dir/$stamp-$n.log"; n=$((n + 1)); done
( cd "$root" && "$@" ) < /dev/null > "$log" 2>&1
rc=$?
# prune: keep the newest 20
ls -1t "$dir"/*.log 2>/dev/null | awk 'NR > 20' | while IFS= read -r old; do rm -f "$old"; done
rel=${log#"$root"/}
[ -n "${DSH_FEEDBACK_LOG_OUT:-}" ] && printf '%s\n' "$log" > "$DSH_FEEDBACK_LOG_OUT"
if [ "$raw" = 1 ]; then cat "$log"; printf 'Raw output kept: %s lines — %s\n' "$(wc -l < "$log" | tr -d ' ')" "$rel"; exit $rc; fi
# records; a record whose suite has a source file under a test-draft root is a DRAFT. The draft
# files are listed ONCE, in the shell, and the awk program reads the list from the environment
# (never a shell string built from a suite name -- `Foo$Bar` is a legal simple name): a suite is a
# draft when `/<Simple>.scala` ends one of the listed paths. The list is bounded to the project's
# own trees -- the harness's fixture roots (.dsh/engine/tests/cases/*/root/**) hold a `test-draft/src/`
# copy of a real suite's name, and `out/` may hold a compiled copy; a bare `find "$root"` saw both
# and rendered a REAL failure as DRAFT, i.e. non-blocking. With the coverage map present, only
# `<module dir>/test-draft/src` of the modules it lists is searched.
drafts=''
map="$(state_dir)/modules.tsv"
if [ -f "$map" ]; then
  while IFS="$(printf '\t')" read -r mdir _mod _caps; do
    [ -n "$mdir" ] || continue
    case "$mdir" in .|'') ddir="$root/test-draft/src" ;; *) ddir="$root/$mdir/test-draft/src" ;; esac
    [ -d "$ddir" ] || continue
    found=$(find "$ddir" -name '*.scala' -print 2>/dev/null)
    [ -n "$found" ] && drafts="$drafts$found
"
  done <<EOF_MAP
$(cat "$map")
EOF_MAP
else
  drafts=$(dsh_find_pruned "$root" \( -name out -o -name target \) -prune -o -path '*/test-draft/src/*' -name '*.scala' -print)
fi
dsh_feedback_parse "$adapter" "$root" "$rc" < "$log" | DSH_DRAFTS="$drafts" awk -F'\t' '
  BEGIN { drafts = "\n" ENVIRON["DSH_DRAFTS"] "\n" }
  function is_draft(s, n, seg) {
    n = split(s, seg, "."); if (n == 0) return 0
    return index(drafts, "/" seg[n] ".scala\n") > 0
  }
  $1 == "kind" { held = $0; next }
  $1 == "suite" && held != "" { print held; if ($2 != "-" && is_draft($2)) print "draft\t1"; held = ""; print; next }
  { if (held != "") { print held; held = "" } print }
  END { if (held != "") print held }' | dsh_instructions_annotate "$root" "$(state_dir)/instructions-missing" | dsh_render_feedback "$selector" "$rel"
exit $rc
