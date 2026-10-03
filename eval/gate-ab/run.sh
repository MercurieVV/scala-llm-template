#!/bin/sh
# One evaluation run: run.sh <task> <g|u> <rep>. Builds the run dir from the task's base tree, runs the agent, collects artefacts.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
[ $# -eq 3 ] || ga_die "usage: run.sh <task> <g|u> <rep>"
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
if [ "$arm" = g ]; then
  git -C "$GA_HOLDOUT_SRC" archive "$GA_HOLDOUT_COMMIT" | { mkdir -p "$rd/holdout" && tar -x -C "$rd/holdout"; } || ga_die "holdout export"
  hd=$(CDPATH= cd -- "$rd/holdout" && pwd -P)
  sed "s|$GA_HOLDOUT_SRC|$hd|g" "$GA_SKREEEP2/.claude/settings.json" > "$rd/repo/.claude/settings.json"
  sed -i.bak "s|^holdoutDir *=.*|holdoutDir = $hd|" "$rd/repo/.dsh/contract" && rm -f "$rd/repo/.dsh/contract.bak"
else
  printf '{"permissions":{}}\n' > "$rd/repo/.claude/settings.json"
fi
cp "$rd/repo/.claude/settings.json" "$rd/settings.json"
( cd "$rd/repo" && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qam "arm $arm" --allow-empty && git tag base )
start=$(date +%s)
( cd "$rd/repo" && python3 "$GA_HOME/timeout.py" "$GA_CAP_SECONDS" -- "${CLAUDE_BIN:-claude}" -p "$(cat "$rd/prompt.txt")" \
    --model "$GA_MODEL" --output-format stream-json --verbose \
    --permission-mode acceptEdits --allowedTools Bash Edit Write Read Grep Glob mcp__scala-semantic ) \
  > "$rd/transcript.jsonl" 2> "$rd/agent-stderr.log"
rc=$?; end=$(date +%s)
to=false; [ "$rc" -eq 124 ] && to=true
printf '{"run_id":"%s","task":"%s","arm":"%s","rep":%s,"start_epoch":%s,"end_epoch":%s,"exit_code":%s,"timed_out":%s}\n' \
  "$id" "$task" "$arm" "$rep" "$start" "$end" "$rc" "$to" > "$rd/run.json"
( cd "$rd/repo" && git add -A -N . && git diff base -- . ':!out' ':!out-agent' ':!out-holdout' > "$rd/final.diff" )
tar -czf "$rd/final-tree.tar.gz" -C "$rd" --exclude 'repo/out' --exclude 'repo/out-agent' --exclude 'repo/out-holdout' repo
echo "run $id: exit $rc, $((end-start)) s"
