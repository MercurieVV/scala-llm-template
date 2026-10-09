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
# score_error <id>: "" when score.json has error null, "none" when absent, else the error text (unreadable counts as an error).
score_error() {
  [ -f "$GA_ROOT/runs/$1/score.json" ] || { echo none; return 0; }
  python3 -c "import json,sys;e=json.load(open(sys.argv[1])).get('error');print('' if e is None else e)" "$GA_ROOT/runs/$1/score.json" 2>/dev/null || echo unreadable
}
# A score.json with a non-null error is not done (score.py writes one while still running, and on interruption / infra failure).
# One automatic retry per run per invocation: an error containing "no result event" or "agent api error", or no run.json -> redo the run; otherwise rescore only.
one() {
  id=$(ga_run_id "$1" "$2" "$3") || exit 1
  rd=$GA_ROOT/runs/$id; e=$(score_error "$id"); how=run
  if [ "$e" = none ]; then how=run
  elif [ -z "$e" ]; then echo "skip $id"; return 0
  elif [ ! -f "$rd/run.json" ]; then how=rerun
  else case $e in *"no result event"*|*"agent api error"*) how=rerun ;; *) how=rescore ;; esac; fi
  rc=-
  if [ "$how" != rescore ]; then $run "$1" "$2" "$3"; rc=$?; fi
  $sc "$rd"
  s=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('solved'))" "$rd/score.json" 2>/dev/null || echo none)
  [ "$how" = run ] && note= || note=" retry=$how(was: $e)"
  printf '%s %s exit=%s solved=%s%s\n' "$(date '+%F %T')" "$id" "$rc" "$s" "$note" >> "$GA_ROOT/campaign.log"
}
mkdir -p "$GA_ROOT/runs"
# Ruling 27: GA_REPS, a space-separated rep list (default "1 2 3"), each 1..4 (4: room for a test phase's fresh reps).
reps=${GA_REPS:-1 2 3}
[ -n "$(echo $reps)" ] || ga_die "GA_REPS is empty"
for r in $reps; do case $r in 1|2|3|4) ;; *) ga_die "GA_REPS: invalid rep '$r' (want 1..4)" ;; esac; done
# Gate ablation: GA_ARMS (default "g u", each g, u or t) and GA_TASKS (default all 8, each a known task).
arms=${GA_ARMS:-g u}
[ -n "$(echo $arms)" ] || ga_die "GA_ARMS is empty"
for a in $arms; do case $a in g|u|t) ;; *) ga_die "GA_ARMS: invalid arm '$a' (want g, u or t)" ;; esac; done
[ -n "$(echo $GA_TASKS)" ] || ga_die "GA_TASKS is empty"
for t in $GA_TASKS; do case " $GA_ALL_TASKS " in *" $t "*) ;; *) ga_die "GA_TASKS: unknown task '$t'" ;; esac; done
if [ "${1:-}" = --smoke ]; then tasks=midi-synth; else tasks=$GA_TASKS; fi

# Preflight: readable dirs, every needed task prepared and validated, HEAD baseline cached, gated settings snapshotted.
ga_unlock_all
# Ruling 22: skreeep2's .claude is live, untracked state; every gated run of this campaign uses one frozen copy.
snap=$GA_ROOT/gated-settings.json
if [ ! -f "$snap" ]; then
  cp "$GA_SKREEEP2/.claude/settings.json" "$snap.tmp" || ga_die "cannot snapshot $GA_SKREEEP2/.claude/settings.json"
  python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$snap.tmp" > "$snap.sha256" || ga_die "hash"
  mv "$snap.tmp" "$snap"
  echo "gated settings snapshot: $snap ($(cat "$snap.sha256"))"
fi
for task in $tasks; do
  v=$GA_ROOT/base/$task/validation.txt
  # 3 lines, or 4 for a GATE_VISIBLE task (gate_visible_on_cut); every line must be yes.
  n=$(wc -l < "$v" 2>/dev/null | tr -d ' ')
  if [ "$(grep -c '=yes$' "$v" 2>/dev/null)" != "$n" ] || { [ "$n" != 3 ] && [ "$n" != 4 ]; }; then
    echo "prepare $task"
    $prep "$task" || ga_die "prepare $task failed (see $GA_ROOT/base/$task)"
  fi
done
[ -f "$GA_ROOT/head-baseline.json" ] || $bl || ga_die "HEAD baseline failed"

if [ "${1:-}" = --smoke ]; then one midi-synth g 9; one midi-synth u 9; exit 0; fi
for rep in $reps; do for task in $tasks; do for arm in $arms; do one "$task" "$arm" "$rep"; done; done; done
