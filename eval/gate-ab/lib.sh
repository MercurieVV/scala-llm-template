# eval/gate-ab/lib.sh — sourced, never executed. Paths and constants for the gate A/B evaluation.
GA_HOME=${GA_HOME:-$(CDPATH= cd -- "$(dirname -- "${GA_LIB_PATH:-$0}")" 2>/dev/null && pwd)}
GA_ROOT=${GA_ROOT:-$HOME/gate-eval}
GA_SKREEEP2=${GA_SKREEEP2:-/Users/viktorskalinins/IdeaProjects/skreeep2}
GA_COMMIT=${GA_COMMIT:-6bf6c1b}
GA_HOLDOUT_SRC=${GA_HOLDOUT_SRC:-/Users/viktorskalinins/IdeaProjects/skreeep2-holdout}
GA_HOLDOUT_COMMIT=${GA_HOLDOUT_COMMIT:-8207d2f}
GA_CAP_SECONDS=${GA_CAP_SECONDS:-2700}
GA_MODEL=${GA_MODEL:-sonnet}
GA_ALL_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth adsr sine by-offset sines-gen fr-pan fr-tuning fr-mode-leds fr-exclusive-solo"
# The 4 gate-visible tasks (spec 2026-10-09) run only when named in GA_TASKS.
GA_AB_TASKS="noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"
GA_TASKS=${GA_TASKS:-$GA_AB_TASKS}

ga_die() { printf 'gate-ab: %s\n' "$1" >&2; exit 1; }

ga_task_env() {
  [ -f "$GA_HOME/tasks/$1/task.env" ] || ga_die "no task $1 ($GA_HOME/tasks/$1/task.env)"
  . "$GA_HOME/tasks/$1/task.env"
}
GA_TEMPLATE=${GA_TEMPLATE:-$(CDPATH= cd -- "$GA_HOME/../.." 2>/dev/null && pwd)}

# Gated arms gf/gs (spec 2026-10-10 §5): the current template engine in the run copy, the arm's turn-end mode frozen and committed.
ga_install_engine() {
  case $2 in full|safety) ;; *) ga_die "turn-end mode must be full or safety, got $2" ;; esac
  sh "$GA_TEMPLATE/kit/harness/install.sh" "$1" >/dev/null || ga_die "engine install into $1 failed"
  printf '# gate-eval arm\nmode\t%s\n' "$2" > "$1/.dsh/policy/turn-end.tsv"
  grep -q '^\.dsh/policy/turn-end\.tsv	' "$1/.dsh/frozen-paths" 2>/dev/null ||
    printf '.dsh/policy/turn-end.tsv\tthe turn-end mode is the human'"'"'s\n' >> "$1/.dsh/frozen-paths"
  ( cd "$1" && git add .dsh && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm "engine, turn-end mode $2" --allow-empty ) ||
    ga_die "commit engine in $1 failed"
}


ga_sha256() {  # <file>
  python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"
}

ga_run_id() {
  case $2 in g|u|t|gf|gs|p) ;; *) ga_die "arm must be g, u, t, gf, gs or p, got $2" ;; esac
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

# Arm p (spec 2026-10-11): the tool-policy hook alone -- no sandbox, no other hook event, no other PreToolUse entry.
ga_policy_only_settings() {  # <settings.json>, rewritten in place
  python3 - "$1" <<'PY' || ga_die "arm p: no tool-policy PreToolUse entry in $1"
import json, sys
p = sys.argv[1]; s = json.load(open(p))
pre = [e for e in (s.get("hooks") or {}).get("PreToolUse", [])
       if any('gate.sh" tool-policy' in h.get("command", "") for h in e.get("hooks", []))]
if not pre: sys.exit(1)
s["hooks"] = {"PreToolUse": pre}; s.pop("sandbox", None)
json.dump(s, open(p, "w"), indent=2)
PY
}

# FR tasks: the reference patch must apply to <dir> (a HEAD copy) before any Mill run.
ga_check_patch() {
  p=$GA_HOME/tasks/$1/$REFERENCE_PATCH
  [ -f "$p" ] || ga_die "reference patch $p missing"
  git -C "$2" apply --check "$p" 2>/dev/null || ga_die "reference patch $p does not apply to $2"
}
