#!/bin/sh
# Build ~/gate-eval/base/<task>/: the cut tree (no git history), the hidden spec outside it, and a validation record.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 1 ] || ga_die "usage: prepare.sh <task>"
task=$1; ga_task_env "$task"
base=$GA_ROOT/base/$task
rm -rf "$base"; mkdir -p "$base/tree" "$base/hidden"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$base/tree" || ga_die "git archive failed"
mkdir -p "$base/hidden/$(dirname "$HIDDEN_SPEC")"
mv "$base/tree/$HIDDEN_SPEC" "$base/hidden/$HIDDEN_SPEC" || ga_die "hidden spec $HIDDEN_SPEC not in tree"
for f in $CUT_FILES; do cp "$GA_HOME/tasks/$task/stub/$f" "$base/tree/$f" || ga_die "stub $f"; done
( cd "$base/tree" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm base ) || ga_die "git init"

mill_in() { # <cap-seconds> <dir> <args...>: Mill with a private output dir, warm-started from the cache
  cap=$1; d=$2; shift 2
  [ -d "$GA_ROOT/cache/out" ] && [ ! -d "$d/out" ] && cp -R "$GA_ROOT/cache/out" "$d/out"
  ( cd "$d" && MILL_OUTPUT_DIR=out python3 "$GA_HOME/timeout.py" "$cap" -- ./mill --no-daemon -j 1 --ticker false --color false "$@" )
}

v=$base/validate; rm -rf "$v"; cp -R "$base/tree" "$v"
mill_in 1800 "$v" __.compile >"$base/cut-compile.log" 2>&1 && c=yes || c=no
mkdir -p "$v/$(dirname "$HIDDEN_SPEC")"; cp "$base/hidden/$HIDDEN_SPEC" "$v/$HIDDEN_SPEC"
mill_in 600 "$v" "$TASK_MODULE" >"$base/hidden-on-cut.log" 2>&1 && f=no || f=yes
h=$GA_ROOT/head
[ -d "$h" ] || ga_die "no $h — run warm-cache.sh first"
mill_in 600 "$h" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
rm -rf "$v"
printf 'cut_compiles=%s\nhidden_fails_on_cut=%s\nhidden_passes_on_head=%s\n' "$c" "$f" "$p" | tee "$base/validation.txt"
[ "$c$f$p" = yesyesyes ]
