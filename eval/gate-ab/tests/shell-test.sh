#!/bin/sh
# Tests for eval/gate-ab shell pieces. Runs under sh and dash. SH=dash sh tests/shell-test.sh to pick the shell.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ga=$(CDPATH= cd -- "$here/.." && pwd)
SH=${SH:-sh}
passed=0; failed=0
ok() { passed=$((passed+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1${2:+ -- $2}"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "wanted [$3], got [$2]"; fi; }

# --- lib.sh
out=$($SH -c ". '$ga/lib.sh'; ga_run_id noise g 1")
check "run id" "$out" "noise-g-1"
$SH -c ". '$ga/lib.sh'; ga_run_id noise x 1" >/dev/null 2>&1; check "run id rejects arm x" "$?" "1"
$SH -c ". '$ga/lib.sh'; ga_run_id noise g 0" >/dev/null 2>&1; check "run id rejects rep 0" "$?" "1"
out=$($SH -c "GA_ROOT=/tmp/x; . '$ga/lib.sh'; echo \$GA_ROOT")
check "GA_ROOT override" "$out" "/tmp/x"
out=$($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS" | wc -w | tr -d ' ')
check "eight tasks" "$out" "8"

# --- timeout.py
python3 "$ga/timeout.py" 5 -- sh -c 'exit 3'; check "timeout passes exit code" "$?" "3"
start=$(date +%s)
python3 "$ga/timeout.py" 1 -- sh -c 'sleep 30 & sleep 30'; rc=$?
took=$(( $(date +%s) - start ))
check "timeout returns 124" "$rc" "124"
[ "$took" -lt 15 ] && ok "timeout kills the group fast" || bad "timeout kills the group fast" "took ${took}s"

# Test that SIGKILL kills surviving children after SIGTERM grace period
pidfile=$(mktemp)
python3 "$ga/timeout.py" 1 -- sh -c "trap '' TERM; (sh -c 'echo \$\$ > $pidfile; trap \"\" TERM; sleep 30') & sleep 30"; rc=$?
if [ "$rc" = "124" ] && [ -f "$pidfile" ]; then
  child_pid=$(cat "$pidfile")
  if ! kill -0 "$child_pid" 2>/dev/null; then
    ok "timeout kills surviving children"
  else
    bad "timeout kills surviving children" "child process $child_pid still running"
  fi
else
  bad "timeout kills surviving children" "rc=$rc or pidfile missing"
fi
rm -f "$pidfile" 2>/dev/null

# --- task definitions
for t in $($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS"); do
  d="$ga/tasks/$t"
  [ -f "$d/task.env" ] && [ -f "$d/prompt.txt" ] || { bad "task $t has task.env and prompt.txt"; continue; }
  ( . "$d/task.env"
    for f in $CUT_FILES; do [ -f "$d/stub/$f" ] || exit 1; grep -q '???' "$d/stub/$f" || exit 1; done
    [ -n "$TASK_MODULE" ] && [ -n "$HIDDEN_SPEC" ] && [ -n "$FEATURE" ] ) && ok "task $t complete" || bad "task $t complete"
  grep -q 'Stop when you are done.' "$d/prompt.txt" && ok "task $t prompt" || bad "task $t prompt"
done

echo "shell-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
