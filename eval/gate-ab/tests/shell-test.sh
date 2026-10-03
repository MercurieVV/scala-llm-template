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

# --- run.sh against fakes
tmp=$(mktemp -d)
mkdir -p "$tmp/home/tasks/t1" "$tmp/root/base/t1/tree/.dsh" "$tmp/skr/.claude" "$tmp/hsrc"
cp "$ga/lib.sh" "$ga/timeout.py" "$ga/run.sh" "$tmp/home/" 2>/dev/null
printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='x'\nCUT_FILES='x'\nFEATURE='f'\n" >"$tmp/home/tasks/t1/task.env"
echo 'do the task' >"$tmp/home/tasks/t1/prompt.txt"
( cd "$tmp/root/base/t1/tree" && printf 'holdoutDir = ../x\n' >.dsh/contract && printf '.claude/\nout/\nout-agent/\n' >.gitignore \
  && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm base )
( cd "$tmp/hsrc" && echo spec >HSpec.scala && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm h )
echo "{\"denyRead\":\"$tmp/hsrc/bin/check\",\"denyWrite\":\"$tmp/hsrc\"}" >"$tmp/skr/.claude/settings.json"
mkdir -p "$tmp/root/base/t1/hidden" "$tmp/root/head" "$tmp/root/runs/other-u-1"
cat >"$tmp/claude" <<'FAKE'
#!/bin/sh
ls -a . >"$FAKE_LS"
printf '%s\n' "$@" >"$FAKE_ARGS"
cat | wc -c | tr -d ' ' >"$FAKE_ARGS.stdin"
for p in $FAKE_PROBE; do if ls "$p" >/dev/null 2>&1; then echo "readable $p"; else echo "denied $p"; fi; done >"$FAKE_PROBED"
mkdir -p out out-agent; echo junk >out/junk.txt; echo junk >out-agent/junk.txt
echo '{"type":"system"}'; echo '{"type":"result"}'
echo 'agent wrote this' >>agent-note.txt
[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"
exit 0
FAKE
chmod +x "$tmp/claude"
runenv() { GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$tmp/skr GA_HOLDOUT_SRC=$tmp/hsrc GA_HOLDOUT_COMMIT=HEAD CLAUDE_BIN=$tmp/claude env "$@"; }
rd=$tmp/root/runs
probe="$tmp/root/base/t1/hidden $tmp/root/head $tmp/root/runs/other-u-1"
runenv FAKE_ARGS=$tmp/args-g.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-g.txt FAKE_LS=$tmp/ls-g.txt $SH "$tmp/home/run.sh" t1 g 1 >/dev/null 2>&1; check "run g exit 0" "$?" "0"
grep -q '"timed_out":false' "$rd/t1-g-1/run.json" && ok "run g not timed out" || bad "run g not timed out"
hd=$(CDPATH= cd -- "$rd/t1-g-1/holdout" && pwd -P)
grep -q "$hd" "$rd/t1-g-1/repo/.claude/settings.json" && ! grep -q "$tmp/hsrc" "$rd/t1-g-1/repo/.claude/settings.json" && ok "run g settings rewritten" || bad "run g settings rewritten"
check "run g contract holdoutDir" "$(cat "$rd/t1-g-1/repo/.dsh/contract")" "holdoutDir = $hd"
[ -f "$rd/t1-g-1/holdout/HSpec.scala" ] && ok "run g holdout exported" || bad "run g holdout exported"
cmp -s "$rd/t1-g-1/settings.json" "$rd/t1-g-1/repo/.claude/settings.json" && ok "run g settings copy" || bad "run g settings copy"
grep -q 'agent wrote this' "$rd/t1-g-1/final.diff" && ok "run g final.diff" || bad "run g final.diff"
[ -f "$rd/t1-g-1/final-tree.tar.gz" ] && ok "run g tarball" || bad "run g tarball"
[ -s "$rd/t1-g-1/transcript.jsonl" ] && ok "run g transcript" || bad "run g transcript"
git -C "$rd/t1-g-1/repo" rev-parse -q --verify refs/tags/base >/dev/null && ok "run g base tag" || bad "run g base tag"
[ -s "$tmp/ls-g.txt" ] && [ ! -e "$tmp/root/cache" ] && ! grep -qx out "$tmp/ls-g.txt" && ! grep -qx 'out-agent' "$tmp/ls-g.txt" && ok "run g no out dirs at start" || bad "run g no out dirs at start"
runenv FAKE_ARGS=$tmp/args-u.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-u.txt FAKE_LS=$tmp/ls-u.txt $SH "$tmp/home/run.sh" t1 u 1 >/dev/null 2>&1; check "run u exit 0" "$?" "0"
check "run u settings" "$(cat "$rd/t1-u-1/repo/.claude/settings.json")" '{"permissions":{}}'
[ ! -e "$rd/t1-u-1/holdout" ] && ok "run u no holdout" || bad "run u no holdout"
[ -s "$tmp/ls-u.txt" ] && ! grep -qx out "$tmp/ls-u.txt" && ! grep -qx 'out-agent' "$tmp/ls-u.txt" && ok "run u no out dirs at start" || bad "run u no out dirs at start"
for arm in g u; do
  check "run $arm isolation denied during run" "$(grep -c '^denied' "$tmp/probed-$arm.txt")" "3"
done
readable=yes; for p in $probe; do ls "$p" >/dev/null 2>&1 || readable=no; done
check "isolation restored after run" "$readable" "yes"
check "agent receives prompt" "$(grep -c '^do the task$' "$tmp/args-g.txt")" "1"
check "agent stdin is empty" "$(cat "$tmp/args-u.txt.stdin")" "0"
grep -q '"scala-semantic"' "$rd/t1-g-1/repo/.mcp.json" && grep -q 'scalasemantic-mcp' "$rd/t1-u-1/repo/.mcp.json" && ok "run .mcp.json written" || bad "run .mcp.json written"
check "run g settings has two rewritten entries" "$(grep -o "$hd" "$rd/t1-g-1/repo/.claude/settings.json" | wc -l | tr -d ' ')" "2"
for arm in g u; do
  if [ -s "$rd/t1-$arm-1/final.diff" ] && ! grep -q 'junk' "$rd/t1-$arm-1/final.diff" && ! tar -tzf "$rd/t1-$arm-1/final-tree.tar.gz" | grep -q 'repo/out'; then ok "run $arm out dirs excluded from artefacts"; else bad "run $arm out dirs excluded from artefacts"; fi
done
runenv GA_CAP_SECONDS=1 FAKE_SLEEP=20 FAKE_ARGS=$tmp/args-t.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-t.txt FAKE_LS=$tmp/ls-t.txt $SH "$tmp/home/run.sh" t1 u 2 >/dev/null 2>&1
grep -q '"timed_out":true' "$rd/t1-u-2/run.json" && ok "run timeout recorded" || bad "run timeout recorded"
[ -f "$rd/t1-u-2/final.diff" ] && [ -f "$rd/t1-u-2/final-tree.tar.gz" ] && ok "run timeout keeps artefacts" || bad "run timeout keeps artefacts"
readable=yes; for p in $probe; do ls "$p" >/dev/null 2>&1 || readable=no; done
check "isolation restored after timeout" "$readable" "yes"
# gated rewrite must verify itself: a contract without holdoutDir aborts before the agent starts
rm -f "$tmp/ls-bad.txt"
( cd "$tmp/root/base/t1/tree" && git checkout -q -b nohd && printf 'other = 1\n' >.dsh/contract && git -c user.name=t -c user.email=t@t commit -qam nohd )
runenv FAKE_ARGS=$tmp/args-b.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-b.txt FAKE_LS=$tmp/ls-bad.txt $SH "$tmp/home/run.sh" t1 g 2 >/dev/null 2>&1
rc=$?; [ "$rc" -ne 0 ] && [ ! -e "$tmp/ls-bad.txt" ] && ok "run aborts when holdoutDir rewrite fails" || bad "run aborts when holdoutDir rewrite fails" "rc=$rc"
# crash safety net
chmod 000 "$tmp/root/head" "$tmp/root/base"
sh -c ". '$ga/lib.sh'; GA_ROOT='$tmp/root' ga_unlock_all"
readable=yes; for p in $probe; do ls "$p" >/dev/null 2>&1 || readable=no; done
check "ga_unlock_all restores access" "$readable" "yes"
rm -rf "$tmp"

echo "shell-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
