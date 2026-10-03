# eval/gate-ab/lib.sh — sourced, never executed. Paths and constants for the gate A/B evaluation.
GA_HOME=${GA_HOME:-$(CDPATH= cd -- "$(dirname -- "${GA_LIB_PATH:-$0}")" 2>/dev/null && pwd)}
GA_ROOT=${GA_ROOT:-$HOME/gate-eval}
GA_SKREEEP2=${GA_SKREEEP2:-/Users/viktorskalinins/IdeaProjects/skreeep2}
GA_COMMIT=${GA_COMMIT:-6bf6c1b}
GA_HOLDOUT_SRC=${GA_HOLDOUT_SRC:-/Users/viktorskalinins/IdeaProjects/skreeep2-holdout}
GA_HOLDOUT_COMMIT=${GA_HOLDOUT_COMMIT:-8207d2f}
GA_CAP_SECONDS=${GA_CAP_SECONDS:-2700}
GA_MODEL=${GA_MODEL:-sonnet}
GA_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"

ga_die() { printf 'gate-ab: %s\n' "$1" >&2; exit 1; }

ga_task_env() {
  [ -f "$GA_HOME/tasks/$1/task.env" ] || ga_die "no task $1 ($GA_HOME/tasks/$1/task.env)"
  . "$GA_HOME/tasks/$1/task.env"
}

ga_run_id() {
  case $2 in g|u) ;; *) ga_die "arm must be g or u, got $2" ;; esac
  case $3 in [1-9]) ;; *) ga_die "rep must be 1..9, got $3" ;; esac
  printf '%s-%s-%s\n' "$1" "$2" "$3"
}

# Safety net after a crashed run: make base/, head/ and every run dir readable again.
ga_unlock_all() {
  for d in "$GA_ROOT/base" "$GA_ROOT/head" "$GA_ROOT"/runs/*; do
    [ -d "$d" ] && chmod 755 "$d"
  done
  return 0
}
