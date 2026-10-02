#!/bin/sh
# Which Mill module owns a changed source path, and which checks that module has.
#
# Prints `<module id>` TAB `<capabilities>` for $1, or `-` when no module owns it. The map is the
# build's own answer (`./mill moduleMap`), cached in `.dsh/.state/modules.tsv` and regenerated
# whenever build.mill is newer than the cache — so the gate's path->module lookup cannot drift from
# the module graph the way a hand-kept list would.
#
# The capabilities are the repository's own gate membership, comma-separated in a fixed order, so the
# gate can never run a check this build deliberately does not run:
#
#   fmt       the module is in `mainModules` — what `preCommit` reformats — so the gate may run
#             `<id>.checkFormat` (`mainModules` are all `Common`s, so that task exists).
#   scalafix  the module is in `scalafixModules` — what `preCommit` runs `fix("--check")` and
#             `fixStrict` on. A `Layer` that list excludes (`handoff.hostdriven`, whose
#             `SuspendSideEffects` findings the repository postponed) does not carry it.
#   tests     the module has a test submodule named `test` that `preCommit` compiles
#             (`testCompileModules`, plus a test module reached through `mainModules`), so the gate may
#             run `<id>.test.compile` for a path under `<dir>/test/`. The name is required, not
#             incidental: a test submodule under any other name would make that selector unresolvable.
#
# `<id>.compile` exists for every module that has a row, so an empty capability string means "compile
# only" and nothing more: `scalafixRules`, `backend.value` and `wiring.details` are in none of the
# lists, so they carry none of the tokens. A test module that is not a `Common` has no row of its own;
# its files resolve to the parent that owns them, and the parent's `tests` capability names the
# submodule to compile. `build.mill` documents the same mapping next to the `moduleMap` command — the
# format has two readers and they have to agree.
#
# Exit status, and what the caller may read from it:
#
#   0  `<id>` TAB `<capabilities>` on stdout — the map owns the path; run exactly those checks.
#   0  `-` on stdout — the map is present and no module owns the path; there is nothing to check.
#   3  a one-line reason on stderr and nothing on stdout — the map is missing or older than
#      build.mill and could not be rebuilt, or the rebuild was refused as malformed. The caller must
#      not read this as "unowned": it has to block (or report) with the reason. A refused refresh used
#      to answer `-` for every path, which reads as "nothing to check" and stands the gate down.
#
# Mill invocations anywhere in the gate must disable the ticker (`--ticker false`): with it on — the
# default even when stdout is a pipe — Mill prefixes every line of a task's stdout with `<n>] `,
# which makes the output unparseable and dirties the diagnostics shown to an agent. That is why the
# refresh below passes it, and why the map it installs is validated before it is installed.
#
# Usage: sh .dsh/engine/module-map.sh <absolute source path>
#        sh .dsh/engine/module-map.sh --dependents <module id>   (field 4: one dependent id per line)
# POSIX sh only: no arrays, no `local`, no `set -e`.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"
# An inherited DSH_HOLDOUT_DIR must not reach an unsandboxed Mill run: only the gate's holdout run sets it (turn-end.sh).
unset DSH_HOLDOUT_DIR
dep_query=''
if [ "${1:-}" = "--dependents" ]; then dep_query=${2:-}; set -- "${2:-}"; fi

root=$(gate_root)
# `pwd -P` on both sides: `pwd` is logical in dash and in bash, so a caller who spells the root (or
# the file) through a symlink — /tmp and /var on macOS are symlinks — would otherwise get `-` for a
# file a module owns. Physical resolution makes both spellings the same path.
root=$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P) || root=$(gate_root)
st=$(state_dir)
mkdir -p "$st" 2>/dev/null
map="$st/modules.tsv"
cannot_decide=''

# Is $1 a map this script can use? Three or four fields per row — `<module dir>`, `<module id>`,
# `<capabilities>` and, from spec 2026-10-01, `<dependents>` — and nothing else: a row that is not
# that owns no path, and a row that lost its third column states nothing about the checks the module
# has, so installing either would silently stop checking a module's files. The capability field may
# be empty (compile-only) but must be present; the accepted shapes are the empty string and every
# comma-separated subset of `fmt`, `scalafix`, `tests` in that order. It is also the guard against
# Mill's ticker, which prefixes every line of a task's stdout with `<n>] `, and against any other
# truncated or partial output. The fourth field, when present, is a comma-separated list of module
# ids (possibly empty): the modules whose `test` suite depends on this one, which turn-end also runs.
map_clean() {
  awk -v dir_re='^[A-Za-z0-9._/-]+$' -v mod_re='^[A-Za-z0-9._-]+$' \
    -v caps_re='^(fmt|tests|fmt,tests|scalafix|scalafix,tests|fmt,scalafix|fmt,scalafix,tests)?$' \
    -v deps_re='^([A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)?$' '
    {
      n = split($0, fields, "\t")
      if (n != 3 && n != 4) bad = 1
      else if (fields[1] !~ dir_re || fields[2] !~ mod_re) bad = 1
      else if (fields[3] !~ caps_re) bad = 1
      else if (n == 4 && fields[4] !~ deps_re) bad = 1
    }
    END { exit !(NR > 0 && !bad) }
  ' "$1"
}

if [ ! -s "$map" ] || [ "$root/build.mill" -nt "$map" ]; then
  # `--ticker false` because with the ticker on — the default even when stdout is a pipe — every row
  # arrives as `1] moduleMap core<TAB>core`, `1] diagnostics<TAB>diagnostics`, ...
  # A failed, partial or adorned run must never replace a good map: write beside it, then rename.
  tmp="$map.tmp.$$"
  mm_mill=$(resolve_mill "$root") || mm_mill=''
  if [ -n "$mm_mill" ] && (cd "$root" && "$mm_mill" --ticker false moduleMap 2>/dev/null) > "$tmp" 2>/dev/null && map_clean "$tmp"; then
    mv "$tmp" "$map"
  else
    rm -f "$tmp"
    if [ -s "$map" ]; then
      cannot_decide="build.mill is newer than the cached $map and ./mill --ticker false moduleMap did not produce a usable one"
    else
      cannot_decide="there is no map at $map and ./mill --ticker false moduleMap did not produce one"
    fi
  fi
fi

if [ -n "$cannot_decide" ]; then
  printf '%s\n' "module-map: cannot decide which module owns '${1:-}' — $cannot_decide" >&2
  exit 3
fi
[ -s "$map" ] || {
  printf '%s\n' "module-map: cannot decide which module owns '${1:-}' — no map at $map" >&2
  exit 3
}

# --dependents <id> (spec 2026-10-01 §2): the row's fourth field, one id per line. A three-column row, an
# empty field or an id with no row print nothing (exit 0); a malformed field 4 cannot decide (exit 3) —
# turn-end must block on that, never read it as "no dependents". Output is captured and printed only
# after the row validated, so a malformed row never leaks a partial list.
if [ -n "$dep_query" ]; then
  dq_out=$(awk -F'\t' -v m="$dep_query" -v deps_re='^([A-Za-z0-9._-]+(,[A-Za-z0-9._-]+)*)?$' '
    $2 == m {
      if (NF >= 4) {
        if ($4 !~ deps_re || NF > 4) { bad = 1; exit }
        n = split($4, d, ",")
        for (i = 1; i <= n; i++) print d[i]
      }
      exit
    }
    END { exit bad ? 3 : 0 }
  ' "$map")
  dq_code=$?
  if [ "$dq_code" != 0 ]; then
    printf '%s\n' "module-map: cannot list the dependents of '$dep_query' — its row in $map has a malformed fourth column" >&2
    exit 3
  fi
  [ -z "$dq_out" ] || printf '%s\n' "$dq_out"
  exit 0
fi

[ "$#" -ge 1 ] && [ -n "${1:-}" ] || { printf '%s\n' '-'; exit 0; }
target_dir=$(CDPATH= cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || { printf '%s\n' '-'; exit 0; }
target="$target_dir/$(basename -- "$1")"

# Longest matching module directory wins, so a nested module is never shadowed by its parent and
# a sibling's directory cannot claim the path. Only directories still in the map count.
best_len=0
best_mod=''
best_caps=''
# Fields are split tab-exactly: tab is IFS whitespace, so `IFS=tab read a b c` merges consecutive tabs
# and an empty-caps four-column row (`x<TAB>x<TAB><TAB>y`) would read its dependents as the caps. The
# `|| [ -n ... ]` keeps a last row that has no trailing newline.
tab=$(printf '\t')
while IFS= read -r row || [ -n "$row" ]; do
  dir=${row%%"$tab"*}
  rest=${row#*"$tab"}
  [ "$rest" != "$row" ] || continue
  module=${rest%%"$tab"*}
  caps=''
  case "$rest" in *"$tab"*) caps=${rest#*"$tab"}; caps=${caps%%"$tab"*} ;; esac
  [ -n "${dir:-}" ] || continue
  [ -n "${module:-}" ] || continue
  case "$dir" in
    .) prefix="$root/" ;;
    *) prefix="$root/$dir/" ;;
  esac
  case "$target" in
    "$prefix"*)
      len=${#prefix}
      if [ "$len" -gt "$best_len" ]; then best_len=$len; best_mod=$module; best_caps=${caps:-}; fi ;;
  esac
done < "$map"

if [ -n "$best_mod" ]; then printf '%s\t%s\n' "$best_mod" "$best_caps"; else printf '%s\n' '-'; fi
