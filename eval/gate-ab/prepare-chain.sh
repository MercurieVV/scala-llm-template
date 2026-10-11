#!/bin/sh
# Chain validation (spec 2026-10-11 chained feature work §3): on HEAD + the chain's reference patches in order (git apply -3),
# every step's hidden spec, every existing test module and the holdout pass. Also the reference erosion line (HEAD + patches 1..k).
# prepare-chain.sh <task>... -> $GA_ROOT/chain-validation.txt, $GA_ROOT/chain-reference-erosion.json
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -ge 1 ] || ga_die "usage: prepare-chain.sh <task>..."
h=$GA_ROOT/head
[ -d "$h/.git" ] || ga_die "no $h — run warm-cache.sh first"
[ -f "$GA_ROOT/head-baseline.json" ] || ga_die "no $GA_ROOT/head-baseline.json — run score.py --baseline first"
ero=${GA_EROSION:-python3 "$GA_HOME/erosion.py"}
cvf=$GA_ROOT/chain-validation.txt; ref=$GA_ROOT/chain-reference-erosion.json; rm -f "$cvf" "$ref"
cv=$GA_ROOT/chain-validate; rm -rf "$cv"; cp -R "$h" "$cv"; rm -rf "$cv/out"
# a copied index carries the source tree's stat data; git apply -3 would see every file as changed
git -C "$cv" update-index -q --refresh >/dev/null 2>&1 || true
mill_in() { # <cap-seconds> <dir> <args...>
  cap=$1; d=$2; shift 2
  ( cd "$d" && MILL_OUTPUT_DIR=out python3 "$GA_HOME/timeout.py" "$cap" -- ./mill --no-daemon -j 1 --ticker false --color false "$@" )
}
ap=yes; rp=no; specs=; tmods=; sep=
printf '[' >"$ref.tmp"
for task in "$@"; do
  HIDDEN_SPEC_SRC=; REFERENCE_PATCH=; ga_task_env "$task"
  [ -n "$REFERENCE_PATCH" ] || ga_die "task $task has no reference patch"
  src=$GA_ROOT/base/$task/hidden/$HIDDEN_SPEC
  [ -f "$src" ] || ga_die "no $src — run prepare.sh $task first"
  if ! ( cd "$cv" && git apply -3 "$GA_HOME/tasks/$task/$REFERENCE_PATCH" &&
         git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm "$task" ) \
       >"$GA_ROOT/chain-apply-$task.log" 2>&1; then
    ap=no; break
  fi
  e=$($ero "$cv" "$h") || ga_die "erosion on the reference after $task failed"
  printf '%s{"task": "%s", %s' "$sep" "$task" "${e#\{}" >>"$ref.tmp"; sep=', '
  specs="$specs $HIDDEN_SPEC=$src"
  case " $tmods " in *" $TASK_MODULE "*) ;; *) tmods="$tmods $TASK_MODULE" ;; esac
done
printf ']\n' >>"$ref.tmp"
if [ "$ap" = yes ]; then
  mv "$ref.tmp" "$ref"
  for s in $specs; do mkdir -p "$cv/$(dirname "${s%%=*}")"; cp "${s#*=}" "$cv/${s%%=*}"; done
  mods=$(python3 -c 'import json,sys;print(" + ".join(sorted(set(json.load(open(sys.argv[1]))["modules"]) | set(sys.argv[2:]))))' \
    "$GA_ROOT/head-baseline.json" $tmods) || ga_die "read $GA_ROOT/head-baseline.json"
  ho=$GA_ROOT/chain-holdout; rm -rf "$ho"; mkdir -p "$ho"
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | tar -x -C "$ho" || ga_die "holdout export"
  hod=$(CDPATH= cd -- "$ho" && pwd -P)
  # shellcheck disable=SC2086
  mill_in 2400 "$cv" -k $mods >"$GA_ROOT/chain-reference-all.log" 2>&1 &&
    ( export DSH_HOLDOUT_DIR="$hod"; mill_in 600 "$cv" holdout.test ) >>"$GA_ROOT/chain-reference-all.log" 2>&1 && rp=yes
  rm -rf "$ho"
else
  rm -f "$ref.tmp"
fi
rm -rf "$cv"
printf 'patches_apply=%s\nreference_passes_all=%s\n' "$ap" "$rp" >"$cvf"
cat "$cvf"
[ "$ap$rp" = yesyes ]
