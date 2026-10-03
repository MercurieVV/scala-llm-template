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

# leader exits on TERM, a TERM-ignoring child survives: the group must still be SIGKILLed
pidfile=$(mktemp)
python3 "$ga/timeout.py" 1 -- sh -c "(sh -c 'echo \$\$ > $pidfile; trap \"\" TERM; sleep 30') & sleep 30"; rc=$?
sleep 1
if [ "$rc" = "124" ] && [ -s "$pidfile" ]; then
  child_pid=$(cat "$pidfile")
  if ! kill -0 "$child_pid" 2>/dev/null; then
    ok "timeout kills surviving children"
  else
    kill -9 "$child_pid" 2>/dev/null
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

# --- prepare.sh against a fake skreeep2
tmp=$(mktemp -d)
fake=$tmp/skreeep2; mkdir -p "$fake/m/src" "$fake/m/test/src" "$tmp/home/tasks/t1/stub/m/src" "$tmp/root/head"
cat >"$fake/mill" <<'MILL'
#!/bin/sh
for a; do t=$a; done
case $PWD in */head) exit 0 ;; esac
case $t in __.compile) exit 0 ;; esac
[ -f m/test/src/ASpec.scala ] && exit 1
exit 0
MILL
chmod +x "$fake/mill"; cp "$fake/mill" "$tmp/root/head/mill"
echo 'object A { def f = 1 }' >"$fake/m/src/A.scala"; echo 'class ASpec' >"$fake/m/test/src/ASpec.scala"
( cd "$fake" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init )
head=$(git -C "$fake" rev-parse HEAD)
printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='m/test/src/ASpec.scala'\nCUT_FILES='m/src/A.scala'\nFEATURE='f'\n" >"$tmp/home/tasks/t1/task.env"
echo 'object A { def f = ??? }' >"$tmp/home/tasks/t1/stub/m/src/A.scala"
cp "$ga/lib.sh" "$ga/timeout.py" "$ga/prepare.sh" "$tmp/home/" 2>/dev/null
GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$fake GA_COMMIT=$head $SH "$tmp/home/prepare.sh" t1 >/dev/null 2>&1
check "prepare exit 0" "$?" "0"
check "prepare validation" "$(cat "$tmp/root/base/t1/validation.txt" 2>/dev/null | tr '\n' ' ')" "cut_compiles=yes hidden_fails_on_cut=yes hidden_passes_on_head=yes "
check "prepare one commit" "$(git -C "$tmp/root/base/t1/tree" rev-list --count HEAD 2>/dev/null)" "1"
[ ! -e "$tmp/root/base/t1/tree/m/test/src/ASpec.scala" ] && [ -f "$tmp/root/base/t1/hidden/m/test/src/ASpec.scala" ] && ok "prepare hides spec" || bad "prepare hides spec"
grep -q '???' "$tmp/root/base/t1/tree/m/src/A.scala" && ok "prepare applies stub" || bad "prepare applies stub"
[ ! -e "$tmp/root/cache" ] && ok "prepare never creates cache" || bad "prepare never creates cache"
rm -rf "$tmp"

echo "shell-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
