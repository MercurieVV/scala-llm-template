#!/bin/sh
# All runs in a fixed interleaved order; resumable — a run with score.json is done, a run dir without one is redone.
# campaign.sh [--smoke]. Runs under `caffeinate -dims` (the Mac slept mid-run once); GA_CAFFEINATED marks the wrapped process.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
if [ -z "${GA_CAFFEINATED:-}" ]; then
  GA_CAFFEINATED=1; export GA_CAFFEINATED
  cf=${GA_CAFFEINATE:-caffeinate -dims}
  # shellcheck disable=SC2086
  if command -v ${cf%% *} >/dev/null 2>&1; then exec $cf sh "$GA_HOME/campaign.sh" "$@"; fi
  echo "gate-ab: caffeinate not found, running unwrapped" >&2
fi
run=${GA_RUN:-sh "$GA_HOME/run.sh"}; sc=${GA_SCORE:-python3 "$GA_HOME/score.py"}
prep=${GA_PREPARE:-sh "$GA_HOME/prepare.sh"}; bl=${GA_BASELINE:-python3 "$GA_HOME/score.py" --baseline}
one() {
  id=$(ga_run_id "$1" "$2" "$3") || exit 1
  [ -f "$GA_ROOT/runs/$id/score.json" ] && { echo "skip $id"; return 0; }
  $run "$1" "$2" "$3"; rc=$?
  $sc "$GA_ROOT/runs/$id"
  s=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('solved'))" "$GA_ROOT/runs/$id/score.json" 2>/dev/null || echo none)
  printf '%s %s exit=%s solved=%s\n' "$(date '+%F %T')" "$id" "$rc" "$s" >> "$GA_ROOT/campaign.log"
}
mkdir -p "$GA_ROOT/runs"
if [ "${1:-}" = --smoke ]; then tasks=midi-synth; else tasks=$GA_TASKS; fi

# Preflight: readable dirs, every needed task prepared and validated, HEAD baseline cached.
ga_unlock_all
for task in $tasks; do
  v=$GA_ROOT/base/$task/validation.txt
  if [ "$(grep -c '=yes$' "$v" 2>/dev/null)" != 3 ] || [ "$(wc -l < "$v" | tr -d ' ')" != 3 ]; then
    echo "prepare $task"
    $prep "$task" || ga_die "prepare $task failed (see $GA_ROOT/base/$task)"
  fi
done
[ -f "$GA_ROOT/head-baseline.json" ] || $bl || ga_die "HEAD baseline failed"

if [ "${1:-}" = --smoke ]; then one midi-synth g 9; one midi-synth u 9; exit 0; fi
for rep in 1 2 3; do for task in $tasks; do for arm in g u; do one "$task" "$arm" "$rep"; done; done; done
