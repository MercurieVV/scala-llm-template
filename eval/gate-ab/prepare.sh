#!/bin/sh
# Build ~/gate-eval/base/<task>/: the cut tree (no git history), the hidden spec outside it, and a validation record.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 1 ] || ga_die "usage: prepare.sh <task>"
task=$1; HIDDEN_SPEC_SRC=; GATE_VISIBLE=; ga_task_env "$task"
base=$GA_ROOT/base/$task
rm -rf "$base"; mkdir -p "$base/tree" "$base/hidden"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$base/tree" || ga_die "git archive failed"
mkdir -p "$base/hidden/$(dirname "$HIDDEN_SPEC")"
if [ -n "${HIDDEN_SPEC_SRC:-}" ]; then
  # Authored for the study: the spec comes from the task folder; the exported tree must not already have one there.
  src=$GA_HOME/tasks/$task/$HIDDEN_SPEC_SRC
  [ -f "$src" ] || { rm -rf "$base"; ga_die "authored hidden spec $src missing"; }
  [ ! -e "$base/tree/$HIDDEN_SPEC" ] || { rm -rf "$base"; ga_die "hidden spec $HIDDEN_SPEC already in the tree; HIDDEN_SPEC_SRC would shadow it"; }
  cp "$src" "$base/hidden/$HIDDEN_SPEC" || ga_die "copy $src"
else
  mv "$base/tree/$HIDDEN_SPEC" "$base/hidden/$HIDDEN_SPEC" || ga_die "hidden spec $HIDDEN_SPEC not in tree"
fi
for f in $CUT_FILES; do cp "$GA_HOME/tasks/$task/stub/$f" "$base/tree/$f" || ga_die "stub $f"; done
( cd "$base/tree" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm base ) || ga_die "git init"

mill_in() { # <cap-seconds> <dir> <args...>: Mill with the tree's own output dir, compiled cold (an out dir is never copied)
  cap=$1; d=$2; shift 2
  ( cd "$d" && MILL_OUTPUT_DIR=out python3 "$GA_HOME/timeout.py" "$cap" -- ./mill --no-daemon -j 1 --ticker false --color false "$@" )
}

v=$base/validate; rm -rf "$v"; cp -R "$base/tree" "$v"
mill_in 1800 "$v" __.compile >"$base/cut-compile.log" 2>&1 && c=yes || c=no
mkdir -p "$v/$(dirname "$HIDDEN_SPEC")"; cp "$base/hidden/$HIDDEN_SPEC" "$v/$HIDDEN_SPEC"
mill_in 600 "$v" "$TASK_MODULE" >"$base/hidden-on-cut.log" 2>&1 && f=no || f=yes
h=$GA_ROOT/head
[ -d "$h" ] || ga_die "no $h — run warm-cache.sh first"
if [ -n "${HIDDEN_SPEC_SRC:-}" ]; then
  # A throwaway copy of HEAD with the authored spec added; HEAD itself stays as exported.
  hv=$base/head-validate; rm -rf "$hv"; cp -R "$h" "$hv"; rm -rf "$hv/out"
  mkdir -p "$hv/$(dirname "$HIDDEN_SPEC")"; cp "$base/hidden/$HIDDEN_SPEC" "$hv/$HIDDEN_SPEC"
  mill_in 1800 "$hv" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
  rm -rf "$hv"
else
  mill_in 600 "$h" "$TASK_MODULE" >"$base/hidden-on-head.log" 2>&1 && p=yes || p=no
fi
g=
if [ "${GATE_VISIBLE:-}" = 1 ]; then
  # Spec 2026-10-09 §4: on the cut tree, some test module other than TASK_MODULE, or the holdout, must fail.
  # Mill runs several tasks in one invocation only when they are joined with "+".
  mods=$(python3 -c 'import json,sys;print(" + ".join(m for m in sorted(json.load(open(sys.argv[1]))["modules"]) if m != sys.argv[2]))' \
    "$GA_ROOT/head-baseline.json" "$TASK_MODULE") || ga_die "read $GA_ROOT/head-baseline.json"
  rm -f "$v/$HIDDEN_SPEC"
  ho=$base/holdout-validate; rm -rf "$ho"; mkdir -p "$ho"
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | tar -x -C "$ho" || ga_die "holdout export"
  hod=$(CDPATH= cd -- "$ho" && pwd -P)
  gl=$base/gate-visible.log
  # shellcheck disable=SC2086
  mill_in 1800 "$v" -k $mods >"$gl" 2>&1; drc=$?
  ( export DSH_HOLDOUT_DIR="$hod"; mill_in 600 "$v" holdout.test ) >"$gl.holdout" 2>&1; hrc=$?
  cat "$gl.holdout" >>"$gl"; rm -f "$gl.holdout"
  rm -rf "$ho"
  # Only a failing test is evidence; a timeout (124), crash or build failure says nothing about visibility.
  for r in $drc $hrc; do [ "$r" != 124 ] || { rm -rf "$v"; ga_die "gate-visible check timed out (see $gl)"; }; done
  if [ "$drc$hrc" = 00 ]; then g=no
  elif grep -Eq 'tests? failed' "$gl"; then g=yes
  else rm -rf "$v"; ga_die "gate-visible check failed without a test failure (see $gl)"; fi
fi
rm -rf "$v"
printf 'cut_compiles=%s\nhidden_fails_on_cut=%s\nhidden_passes_on_head=%s\n' "$c" "$f" "$p" > "$base/validation.txt"
[ -z "$g" ] || printf 'gate_visible_on_cut=%s\n' "$g" >> "$base/validation.txt"
cat "$base/validation.txt"
[ "$c$f$p" = yesyesyes ] && [ "${g:-yes}" = yes ]
