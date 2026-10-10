#!/bin/sh
# One evaluation run: run.sh <task> <g|u|t|gf|gs> <rep>. Builds the run dir from the task's base tree, runs the agent, collects artefacts.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 3 ] || ga_die "usage: run.sh <task> <g|u|t|gf|gs> <rep>"
task=$1; arm=$2; rep=$3; id=$(ga_run_id "$task" "$arm" "$rep") || exit 1
ga_task_env "$task"
base=$GA_ROOT/base/$task
[ -d "$base/tree/.git" ] || ga_die "task $task not prepared (run prepare.sh $task)"
rd=$GA_ROOT/runs/$id
rm -rf "$rd"; mkdir -p "$rd"
cp -R "$base/tree" "$rd/repo"
cp "$GA_HOME/tasks/$task/prompt.txt" "$rd/prompt.txt"
mkdir -p "$rd/repo/.claude"
cat > "$rd/repo/.mcp.json" <<'MCP'
{ "mcpServers": { "scala-semantic": { "command": "/Users/viktorskalinins/.local/bin/scalasemantic-mcp", "args": ["serve", "."] } } }
MCP
gsha=null
if [ "$arm" != u ]; then
  # Ruling 22: the campaign's snapshot of skreeep2's settings (campaign.sh writes it once), never the live file
  snap=$GA_ROOT/gated-settings.json
  [ -f "$snap" ] || ga_die "no gated settings snapshot $snap (campaign.sh writes it)"
  h=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$snap") || ga_die "hash $snap"
  [ ! -f "$snap.sha256" ] || [ "$(cat "$snap.sha256")" = "$h" ] || ga_die "$snap does not match $snap.sha256"
  gsha="\"$h\""
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | { mkdir -p "$rd/holdout" && tar -x -C "$rd/holdout"; } || ga_die "holdout export"
  hd=$(CDPATH= cd -- "$rd/holdout" && pwd -P)
  sed "s|$GA_HOLDOUT_SRC|$hd|g" "$snap" > "$rd/repo/.claude/settings.json"
  if [ "$arm" = t ]; then
    # gate ablation: arm t is the gated arm without the turn-end Stop hook; no Stop hook means t would equal g
    python3 -c 'import json,sys
p=sys.argv[1]; s=json.load(open(p)); h=s.get("hooks")
if not isinstance(h, dict) or "Stop" not in h: sys.exit("no hooks.Stop in the gated snapshot")
del h["Stop"]; json.dump(s, open(p, "w"), indent=2)' "$rd/repo/.claude/settings.json" || ga_die "arm t: cannot remove the Stop hook"
  fi
  case $arm in gf) ga_install_engine "$rd/repo" full ;; gs) ga_install_engine "$rd/repo" safety ;; esac
  sed -i.bak "s|^holdoutDir *=.*|holdoutDir = $hd|" "$rd/repo/.dsh/contract" && rm -f "$rd/repo/.dsh/contract.bak"
  grep -qx "holdoutDir = $hd" "$rd/repo/.dsh/contract" || ga_die "contract rewrite failed (no holdoutDir line?)"
  ! grep -qF "$GA_HOLDOUT_SRC" "$rd/repo/.claude/settings.json" || ga_die "settings still mention $GA_HOLDOUT_SRC"
else
  printf '{"permissions":{}}\n' > "$rd/repo/.claude/settings.json"
fi
cp "$rd/repo/.claude/settings.json" "$rd/settings.json"
( cd "$rd/repo" && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qam "arm $arm" --allow-empty && git tag base )
# Ruling 19: compile the run's own tree into the arm's out dir before the agent starts (outside wall time, before
# locking): classes, test classes, the SemanticDB index the gate's semantic guard and the scala-semantic MCP read, and
# .scala-semantic/classpath-mill.json for the MCP's presentation compiler. Nothing is copied (Ruling 8).
[ "$arm" = u ] && pout=out || pout=out-agent
pc=${GA_PRECOMPILE:-__.compile + __.test.compile + __.semanticDbData + scalaSemanticWriteClasspath}
p0=$(date +%s)
# shellcheck disable=SC2086
( cd "$rd/repo" && set -f && MILL_OUTPUT_DIR=$pout python3 "$GA_HOME/timeout.py" "${GA_PRECOMPILE_CAP:-1800}" -- \
    ./mill --no-daemon -j 1 --ticker false --color false $pc ) > "$rd/precompile.log" 2>&1 || ga_die "precompile failed (see $rd/precompile.log)"
pcs=$(( $(date +%s) - p0 ))
# Isolation: while the agent runs, base/ (hidden specs), head/ (the solution) and other runs are unreadable.
modes=$rd/modes.txt; : > "$modes"
for d in "$GA_ROOT/base" "$GA_ROOT/head" "$GA_ROOT"/runs/*; do
  [ -d "$d" ] || continue
  [ "$d" = "$rd" ] && continue
  m=$(python3 -c 'import os,sys;print(format(os.stat(sys.argv[1]).st_mode&0o7777,"o"))' "$d") || ga_die "stat $d"
  printf '%s %s\n' "$m" "$d" >> "$modes"
done
ga_restore() {
  [ -f "$modes" ] || return 0
  while read -r m d; do chmod "$m" "$d"; done < "$modes"
  rm -f "$modes"
}
trap ga_restore EXIT
trap 'ga_restore; exit 130' INT TERM
while read -r m d; do chmod 000 "$d"; done < "$modes"
# M2: Claude Code keeps auto-memory and transcripts per cwd in <config>/projects/<cwd with / and . as ->; a re-run of the
# same run id would otherwise inherit the previous attempt's memory.
slug=$(CDPATH= cd -- "$rd/repo" && pwd -P | sed 's|[/.]|-|g')
rm -rf "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$slug"
# A campaign started inside a Claude Code session must not hand that session's identity to the agent.
unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_MESSAGING_SOCKET \
  CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_CODE_BRIDGE_SESSION_ID CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_EXECPATH CLAUDE_PID \
  CLAUDE_JOB_DIR CLAUDE_EFFORT AI_AGENT
start=$(date +%s)
# Ruling 20: project settings only, and exactly the MCP servers of .mcp.json (same flags in both arms)
( cd "$rd/repo" && python3 "$GA_HOME/timeout.py" "$GA_CAP_SECONDS" -- "${CLAUDE_BIN:-claude}" -p "$(cat "$rd/prompt.txt")" \
    --model "$GA_MODEL" --output-format stream-json --verbose \
    --setting-sources project --strict-mcp-config --mcp-config .mcp.json \
    --permission-mode acceptEdits --allowedTools Bash Edit Write Read Grep Glob mcp__scala-semantic </dev/null ) \
  > "$rd/transcript.jsonl" 2> "$rd/agent-stderr.log"
rc=$?; end=$(date +%s)
ga_restore
to=false; [ "$rc" -eq 124 ] && to=true
printf '{"run_id":"%s","task":"%s","arm":"%s","rep":%s,"start_epoch":%s,"end_epoch":%s,"exit_code":%s,"timed_out":%s,"precompile_seconds":%s,"gated_settings_sha256":%s}\n' \
  "$id" "$task" "$arm" "$rep" "$start" "$end" "$rc" "$to" "$pcs" "$gsha" > "$rd/run.json"
( cd "$rd/repo" && git add -A -N . && git diff base -- . ':!out' ':!out-agent' ':!out-holdout' > "$rd/final.diff" )
tar -czf "$rd/final-tree.tar.gz" -C "$rd" --exclude 'repo/out' --exclude 'repo/out-agent' --exclude 'repo/out-holdout' repo
echo "run $id: exit $rc, $((end-start)) s (precompile $pcs s)"
