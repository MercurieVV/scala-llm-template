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
out=$($SH -c ". '$ga/lib.sh'; ga_run_id noise t 1")
check "run id arm t" "$out" "noise-t-1"
out=$($SH -c "GA_ROOT=/tmp/x; . '$ga/lib.sh'; echo \$GA_ROOT")
check "GA_ROOT override" "$out" "/tmp/x"
out=$($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS" | wc -w | tr -d ' ')
check "eight tasks" "$out" "8"
out=$(env -u GA_TASKS $SH -c ". '$ga/lib.sh'; echo \$GA_TASKS")
check "default GA_TASKS is all tasks" "$out" "noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth"
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan gf 1")
check "run id arm gf" "$out" "fr-pan-gf-1"
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan gs 2")
check "run id arm gs" "$out" "fr-pan-gs-2"
out=$($SH -c ". '$ga/lib.sh'; case \" \$GA_ALL_TASKS \" in *' fr-exclusive-solo '*) echo yes;; *) echo no;; esac")
check "FR tasks known" "$out" "yes"
GA_ROOT=$(mktemp -d) GA_CAFFEINATED=1 GA_ARMS="gf x" $SH "$ga/campaign.sh" >/dev/null 2>&1; check "campaign rejects arm x beside gf" "$?" "1"
out=$($SH -c ". '$ga/lib.sh'; ga_run_id fr-pan p 1")
check "run id arm p" "$out" "fr-pan-p-1"
GA_ROOT=$(mktemp -d) GA_CAFFEINATED=1 GA_ARMS="p x" $SH "$ga/campaign.sh" >/dev/null 2>&1; check "campaign rejects arm x beside p" "$?" "1"
pf=$(mktemp)
cat > "$pf" <<'J'
{"env":{"MILL_OUTPUT_DIR":"out-agent"},"sandbox":{"enabled":true},"permissions":{"deny":["Read(./holdout/**)"]},
 "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" baseline"}]}],
  "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" tool-policy","timeout":30}]},
   {"matcher":"Read|Bash","hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" semantic-guard"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"sh \"$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh\" turn-end"}]}]}}
J
$SH -c ". '$ga/lib.sh'; ga_policy_only_settings '$pf'"
out=$(python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));h=s["hooks"];print(sorted(h), len(h["PreToolUse"]), "tool-policy" in h["PreToolUse"][0]["hooks"][0]["command"], "sandbox" in s, s["env"]["MILL_OUTPUT_DIR"], s["permissions"]["deny"][0])' "$pf" 2>&1)
check "policy-only settings keep only tool-policy" "$out" "['PreToolUse'] 1 True False out-agent Read(./holdout/**)"
printf '{"hooks":{"Stop":[]}}' > "$pf"
$SH -c ". '$ga/lib.sh'; ga_policy_only_settings '$pf'" >/dev/null 2>&1; check "policy-only settings refuse a snapshot without tool-policy" "$?" "1"

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
for t in $($SH -c ". '$ga/lib.sh'; echo \$GA_TASKS") adsr sine by-offset sines-gen; do
  d="$ga/tasks/$t"
  [ -f "$d/task.env" ] && [ -f "$d/prompt.txt" ] || { bad "task $t has task.env and prompt.txt"; continue; }
  ( . "$d/task.env"
    for f in $CUT_FILES; do [ -f "$d/stub/$f" ] || exit 1; grep -q '???' "$d/stub/$f" || exit 1; done
    [ -z "${HIDDEN_SPEC_SRC:-}" ] || [ -f "$d/$HIDDEN_SPEC_SRC" ] || exit 1
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

# --- prepare.sh: authored hidden spec (HIDDEN_SPEC_SRC) and gate-visible validation
tmp=$(mktemp -d)
fake=$tmp/skreeep2; mkdir -p "$fake/m/src" "$fake/d/src" "$tmp/home/tasks/t2/stub/m/src" "$tmp/home/tasks/t2/hidden/m/test/src" "$tmp/root/head" "$tmp/hsrc"
# fake mill: compile ok; on head everything passes; elsewhere m.test fails iff the hidden spec is present,
# d.test (downstream) fails iff A.scala is cut (unless NO_DOWN), holdout.test fails iff FAIL_HOLDOUT is set.
cat >"$fake/mill" <<'MILL'
#!/bin/sh
case $PWD in */head|*/head-validate) exit 0 ;; esac
# real Mill runs one task per invocation unless tasks are joined with "+": refuse several tasks without it
nt=0; plus=; for a; do case $a in +) plus=1 ;; -*) ;; *.*) nt=$((nt+1)) ;; esac; done
[ "$nt" -gt 1 ] && [ -z "$plus" ] && { echo "several tasks without +" >&2; exit 2; }
[ -n "${MILL_CRASH:-}" ] && [ "$nt" -gt 0 ] && case " $* " in *" d.test "*) exit 3 ;; esac
rc=0
for a; do case $a in
  __.compile) ;;
  m.test) [ -f m/test/src/ASpec.scala ] && rc=1 ;;
  d.test) [ -z "${NO_DOWN:-}" ] && grep -q '???' m/src/A.scala && rc=1 ;;
  holdout.test) [ -n "${FAIL_HOLDOUT:-}" ] && rc=1 ;;
esac; done
[ $rc = 0 ] || echo "[error] fake.test 1 tests failed:"
exit $rc
MILL
chmod +x "$fake/mill"; cp "$fake/mill" "$tmp/root/head/mill"
echo 'object A { def f = 1 }' >"$fake/m/src/A.scala"; echo 'object D' >"$fake/d/src/D.scala"
( cd "$fake" && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm init )
head=$(git -C "$fake" rev-parse HEAD)
( cd "$tmp/hsrc" && echo x >x && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm h )
hhead=$(git -C "$tmp/hsrc" rev-parse HEAD)
printf '{"modules": {"m.test": true, "d.test": true, "e.test": true}}\n' >"$tmp/root/head-baseline.json"
printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='m/test/src/ASpec.scala'\nHIDDEN_SPEC_SRC='hidden/m/test/src/ASpec.scala'\nGATE_VISIBLE=1\nCUT_FILES='m/src/A.scala'\nFEATURE='f'\n" >"$tmp/home/tasks/t2/task.env"
echo 'object A { def f = ??? }' >"$tmp/home/tasks/t2/stub/m/src/A.scala"
echo 'class ASpec' >"$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
cp "$ga/lib.sh" "$ga/timeout.py" "$ga/prepare.sh" "$tmp/home/" 2>/dev/null
# penv [VAR=value ...] cmd: env assignments, never shell-function prefix assignments (their scope differs between shells)
penv() { env GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$fake GA_COMMIT=$head GA_HOLDOUT_SRC=$tmp/hsrc GA_HOLDOUT_COMMIT=$hhead "$@"; }
penv $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1
check "prepare authored exit 0" "$?" "0"
check "prepare authored validation" "$(cat "$tmp/root/base/t2/validation.txt" 2>/dev/null | tr '\n' ' ')" "cut_compiles=yes hidden_fails_on_cut=yes hidden_passes_on_head=yes gate_visible_on_cut=yes "
[ -f "$tmp/root/base/t2/hidden/m/test/src/ASpec.scala" ] && [ ! -e "$tmp/root/base/t2/tree/m/test/src/ASpec.scala" ] && ok "prepare authored spec hidden" || bad "prepare authored spec hidden"
[ ! -e "$tmp/root/head/m/test/src/ASpec.scala" ] && ok "prepare leaves head untouched" || bad "prepare leaves head untouched"
# downstream does not see the cut, holdout passes -> not gate-visible -> exit 1, 4th line no
penv NO_DOWN=1 $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "prepare not gate-visible fails" || bad "prepare not gate-visible fails"
check "prepare not gate-visible line" "$(sed -n 4p "$tmp/root/base/t2/validation.txt" 2>/dev/null)" "gate_visible_on_cut=no"
# holdout failing alone is enough
penv NO_DOWN=1 FAIL_HOLDOUT=1 $SH "$tmp/home/prepare.sh" t2 >/dev/null 2>&1
check "prepare holdout-visible exit 0" "$?" "0"
# a downstream run that fails without a test failure (crash, infra) is not evidence: die, no validation
penv MILL_CRASH=1 $SH "$tmp/home/prepare.sh" t2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'without a test failure' "$tmp/out" && ok "prepare gate-visible crash dies" || bad "prepare gate-visible crash dies"
[ ! -f "$tmp/root/base/t2/validation.txt" ] && ok "prepare crash leaves no validation" || bad "prepare crash leaves no validation"
# missing authored spec -> die
rm "$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
penv $SH "$tmp/home/prepare.sh" t2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'hidden/m/test/src/ASpec.scala' "$tmp/out" && ok "prepare missing authored spec dies" || bad "prepare missing authored spec dies"
[ ! -f "$tmp/root/base/t2/validation.txt" ] && ok "prepare missing spec leaves no validation" || bad "prepare missing spec leaves no validation"
# authored spec would shadow a real one -> die
echo 'class ASpec' >"$tmp/home/tasks/t2/hidden/m/test/src/ASpec.scala"
mkdir -p "$fake/m/test/src"; echo 'class ASpec' >"$fake/m/test/src/ASpec.scala"
( cd "$fake" && git add -A && git -c user.name=t -c user.email=t@t commit -qm real )
penv GA_COMMIT=$(git -C "$fake" rev-parse HEAD) $SH "$tmp/home/prepare.sh" t2 >"$tmp/out" 2>&1; rc=$?
[ "$rc" != 0 ] && grep -q 'already in the tree' "$tmp/out" && ok "prepare authored shadow dies" || bad "prepare authored shadow dies"
rm -rf "$tmp"

# --- run.sh against fakes
tmp=$(mktemp -d)
mkdir -p "$tmp/home/tasks/t1" "$tmp/root/base/t1/tree/.dsh" "$tmp/skr/.claude" "$tmp/hsrc"
cp "$ga/lib.sh" "$ga/timeout.py" "$ga/run.sh" "$tmp/home/" 2>/dev/null
printf "TASK_MODULE='m.test'\nHIDDEN_SPEC='x'\nCUT_FILES='x'\nFEATURE='f'\n" >"$tmp/home/tasks/t1/task.env"
echo 'do the task' >"$tmp/home/tasks/t1/prompt.txt"
# fake ./mill in the task tree: the pre-agent compile (Ruling 19) logs its output dir and args and emits a SemanticDB file
cat >"$tmp/root/base/t1/tree/mill" <<'MILL'
#!/bin/sh
echo "$MILL_OUTPUT_DIR $*" >>"$FAKE_MILL_LOG"
[ -n "${FAKE_MILL_FAIL:-}" ] && exit 1
mkdir -p "$MILL_OUTPUT_DIR/m/semanticDbDataDetailed.dest/classes/META-INF/semanticdb" && : >"$MILL_OUTPUT_DIR/m/semanticDbDataDetailed.dest/classes/META-INF/semanticdb/A.scala.semanticdb"
exit 0
MILL
chmod +x "$tmp/root/base/t1/tree/mill"
( cd "$tmp/root/base/t1/tree" && printf 'holdoutDir = ../x\n' >.dsh/contract && printf '.claude/\nout/\nout-agent/\n' >.gitignore \
  && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm base )
( cd "$tmp/hsrc" && echo spec >HSpec.scala && git init -q && git add -A && git -c user.name=t -c user.email=t@t commit -qm h )
echo '{"live":"not the snapshot"}' >"$tmp/skr/.claude/settings.json"
# Ruling 22: run.sh reads the campaign's snapshot, never the live skreeep2 settings
echo "{\"denyRead\":\"$tmp/hsrc/bin/check\",\"denyWrite\":\"$tmp/hsrc\"}" >"$tmp/root/gated-settings.json"
snapsha=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/root/gated-settings.json")
echo "$snapsha" >"$tmp/root/gated-settings.json.sha256"
mkdir -p "$tmp/root/base/t1/hidden" "$tmp/root/head" "$tmp/root/runs/other-u-1"
cat >"$tmp/claude" <<'FAKE'
#!/bin/sh
ls -a . >"$FAKE_LS"
find . -path '*/META-INF/semanticdb/*.semanticdb' | head -n 1 >"$FAKE_LS.index"
env | grep -c '^CLAUDECODE=' >"$FAKE_LS.env"
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
runenv() { GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$tmp/skr GA_HOLDOUT_SRC=$tmp/hsrc GA_HOLDOUT_COMMIT=HEAD CLAUDE_BIN=$tmp/claude \
  CLAUDE_CONFIG_DIR=$tmp/cfg FAKE_MILL_LOG=$tmp/mill.log CLAUDECODE=1 env "$@"; }
# M2: auto-memory / transcripts of an earlier run with the same id are removed; other projects stay
mkdir -p "$tmp/root/runs/t1-g-1/repo" && slug=$(CDPATH= cd -- "$tmp/root/runs/t1-g-1/repo" && pwd -P | sed 's|[/.]|-|g') && rm -rf "$tmp/root/runs/t1-g-1"
mkdir -p "$tmp/cfg/projects/$slug/memory" "$tmp/cfg/projects/-other-project"; echo old >"$tmp/cfg/projects/$slug/memory/MEMORY.md"
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
[ -s "$tmp/ls-g.txt" ] && [ ! -e "$tmp/root/cache" ] && ! grep -qx out "$tmp/ls-g.txt" && grep -qx 'out-agent' "$tmp/ls-g.txt" && ok "run g only out-agent at start" || bad "run g only out-agent at start"
check "run g precompile into out-agent" "$(grep -c '^out-agent --no-daemon -j 1 --ticker false --color false __.compile + __.test.compile + __.semanticDbData + scalaSemanticWriteClasspath$' "$tmp/mill.log")" "1"
grep -q 'semanticdb/A.scala.semanticdb' "$tmp/ls-g.txt.index" && ok "run g SemanticDB index present at agent start" || bad "run g SemanticDB index present at agent start"
grep -q '"precompile_seconds":[0-9][0-9]*,' "$rd/t1-g-1/run.json" && ok "run g precompile_seconds recorded" || bad "run g precompile_seconds recorded" "$(cat "$rd/t1-g-1/run.json")"
grep -q "\"gated_settings_sha256\":\"$snapsha\"" "$rd/t1-g-1/run.json" && ok "run g snapshot hash recorded" || bad "run g snapshot hash recorded"
! grep -q 'not the snapshot' "$rd/t1-g-1/repo/.claude/settings.json" && ok "run g uses the snapshot, not live settings" || bad "run g uses the snapshot, not live settings"
tr '\n' ' ' <"$tmp/args-g.txt" | grep -q -e ' --setting-sources project --strict-mcp-config --mcp-config .mcp.json ' && ok "run g agent isolation flags" || bad "run g agent isolation flags" "$(tr '\n' ' ' <"$tmp/args-g.txt")"
check "run g outer Claude Code env not inherited" "$(cat "$tmp/ls-g.txt.env")" "0"
[ ! -e "$tmp/cfg/projects/$slug" ] && [ -d "$tmp/cfg/projects/-other-project" ] && ok "run g removes its own Claude project dir only" || bad "run g removes its own Claude project dir only"
runenv FAKE_ARGS=$tmp/args-u.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-u.txt FAKE_LS=$tmp/ls-u.txt $SH "$tmp/home/run.sh" t1 u 1 >/dev/null 2>&1; check "run u exit 0" "$?" "0"
check "run u settings" "$(cat "$rd/t1-u-1/repo/.claude/settings.json")" '{"permissions":{}}'
[ ! -e "$rd/t1-u-1/holdout" ] && ok "run u no holdout" || bad "run u no holdout"
[ -s "$tmp/ls-u.txt" ] && grep -qx out "$tmp/ls-u.txt" && ! grep -qx 'out-agent' "$tmp/ls-u.txt" && ok "run u only out at start" || bad "run u only out at start"
check "run u precompile into out" "$(grep -c '^out --no-daemon .*__.semanticDbData + scalaSemanticWriteClasspath$' "$tmp/mill.log")" "1"
grep -q '"gated_settings_sha256":null' "$rd/t1-u-1/run.json" && ok "run u no snapshot hash" || bad "run u no snapshot hash"
cmp -s "$tmp/args-g.txt" "$tmp/args-u.txt" && ok "agent command line identical in both arms" || bad "agent command line identical in both arms"
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
# Arm t: the gated snapshot without the Stop hook (gate ablation spec §3)
cp "$tmp/root/gated-settings.json" "$tmp/snap.keep"; cp "$tmp/root/gated-settings.json.sha256" "$tmp/snap.keep.sha256"
cat >"$tmp/root/gated-settings.json" <<EOF
{"sandbox":{"denyRead":"$tmp/hsrc/bin/check","denyWrite":"$tmp/hsrc"},"env":{"MILL_OUTPUT_DIR":"out-agent"},
 "hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"tool-policy"}]}],
          "Stop":[{"hooks":[{"type":"command","command":"turn-end"}]}]}}
EOF
python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/root/gated-settings.json" >"$tmp/root/gated-settings.json.sha256"
n0=$(grep -c '^out-agent --no-daemon ' "$tmp/mill.log")
runenv FAKE_ARGS=$tmp/args-tt.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-tt.txt FAKE_LS=$tmp/ls-tt.txt $SH "$tmp/home/run.sh" t1 t 1 >/dev/null 2>&1; check "run t exit 0" "$?" "0"
python3 -c 'import json,sys;s=json.load(open(sys.argv[1]));h=s["hooks"];sys.exit(0 if "Stop" not in h and h["PreToolUse"] and s["env"]["MILL_OUTPUT_DIR"]=="out-agent" else 1)' "$rd/t1-t-1/repo/.claude/settings.json" \
  && ok "run t settings: no Stop, rest kept" || bad "run t settings: no Stop, rest kept" "$(cat "$rd/t1-t-1/repo/.claude/settings.json")"
hdt=$(CDPATH= cd -- "$rd/t1-t-1/holdout" && pwd -P)
grep -q "$hdt" "$rd/t1-t-1/repo/.claude/settings.json" && ! grep -q "$tmp/hsrc" "$rd/t1-t-1/repo/.claude/settings.json" && ok "run t holdout paths rewritten" || bad "run t holdout paths rewritten"
check "run t contract holdoutDir" "$(cat "$rd/t1-t-1/repo/.dsh/contract")" "holdoutDir = $hdt"
check "run t precompile into out-agent" "$(grep -c '^out-agent --no-daemon ' "$tmp/mill.log")" "$((n0 + 1))"
grep -q '"arm":"t"' "$rd/t1-t-1/run.json" && grep -q "\"gated_settings_sha256\":\"$(cat "$tmp/root/gated-settings.json.sha256")\"" "$rd/t1-t-1/run.json" \
  && ok "run t run.json arm and snapshot hash" || bad "run t run.json arm and snapshot hash" "$(cat "$rd/t1-t-1/run.json")"
cmp -s "$tmp/args-g.txt" "$tmp/args-tt.txt" && ok "agent command line identical in arm t" || bad "agent command line identical in arm t"
# a snapshot without a Stop hook would make t identical to g: die before the agent starts
cp "$tmp/snap.keep" "$tmp/root/gated-settings.json"; cp "$tmp/snap.keep.sha256" "$tmp/root/gated-settings.json.sha256"
rm -f "$tmp/ls-t2.txt"
runenv FAKE_ARGS=$tmp/args-t2.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-t2.txt FAKE_LS=$tmp/ls-t2.txt $SH "$tmp/home/run.sh" t1 t 2 >/dev/null 2>&1 \
  && bad "run t without Stop hook dies" || ok "run t without Stop hook dies"
[ ! -e "$tmp/ls-t2.txt" ] && ok "run t without Stop hook: agent not started" || bad "run t without Stop hook: agent not started"

# gated rewrite must verify itself: a contract without holdoutDir aborts before the agent starts
rm -f "$tmp/ls-bad.txt"
( cd "$tmp/root/base/t1/tree" && git checkout -q -b nohd && printf 'other = 1\n' >.dsh/contract && git -c user.name=t -c user.email=t@t commit -qam nohd )
runenv FAKE_ARGS=$tmp/args-b.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-b.txt FAKE_LS=$tmp/ls-bad.txt $SH "$tmp/home/run.sh" t1 g 2 >/dev/null 2>&1
rc=$?; [ "$rc" -ne 0 ] && [ ! -e "$tmp/ls-bad.txt" ] && ok "run aborts when holdoutDir rewrite fails" || bad "run aborts when holdoutDir rewrite fails" "rc=$rc"
( cd "$tmp/root/base/t1/tree" && git checkout -q - )
# a failed pre-agent compile aborts before the agent starts
rm -f "$tmp/ls-pc.txt"
runenv FAKE_MILL_FAIL=1 FAKE_ARGS=$tmp/args-pc.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-pc.txt FAKE_LS=$tmp/ls-pc.txt $SH "$tmp/home/run.sh" t1 u 3 >/dev/null 2>&1
rc=$?; [ "$rc" -ne 0 ] && [ ! -e "$tmp/ls-pc.txt" ] && ok "run aborts when precompile fails" || bad "run aborts when precompile fails" "rc=$rc"
readable=yes; for p in $probe; do ls "$p" >/dev/null 2>&1 || readable=no; done
check "precompile failure leaves isolation unlocked" "$readable" "yes"
# Ruling 22: no snapshot -> the gated arm refuses to start
mv "$tmp/root/gated-settings.json" "$tmp/root/gs.bak"; rm -f "$tmp/ls-ns.txt"
runenv FAKE_ARGS=$tmp/args-ns.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-ns.txt FAKE_LS=$tmp/ls-ns.txt $SH "$tmp/home/run.sh" t1 g 3 >/dev/null 2>&1
rc=$?; [ "$rc" -ne 0 ] && [ ! -e "$tmp/ls-ns.txt" ] && ok "run g dies without settings snapshot" || bad "run g dies without settings snapshot" "rc=$rc"
mv "$tmp/root/gs.bak" "$tmp/root/gated-settings.json"
echo 0000 >"$tmp/root/gated-settings.json.sha256"
runenv FAKE_ARGS=$tmp/args-ns.txt FAKE_PROBE="$probe" FAKE_PROBED=$tmp/probed-ns.txt FAKE_LS=$tmp/ls-ns.txt $SH "$tmp/home/run.sh" t1 g 3 >/dev/null 2>&1
rc=$?; [ "$rc" -ne 0 ] && [ ! -e "$tmp/ls-ns.txt" ] && ok "run g dies when snapshot hash differs" || bad "run g dies when snapshot hash differs" "rc=$rc"
# crash safety net
chmod 000 "$tmp/root/head" "$tmp/root/base"
sh -c ". '$ga/lib.sh'; GA_ROOT='$tmp/root' ga_unlock_all"
readable=yes; for p in $probe; do ls "$p" >/dev/null 2>&1 || readable=no; done
check "ga_unlock_all restores access" "$readable" "yes"
rm -rf "$tmp"

# --- campaign.sh against fakes
tmp=$(mktemp -d)
mkdir -p "$tmp/home" "$tmp/root/base" "$tmp/root/runs/noise-u-1" "$tmp/root/runs/noise-g-1" "$tmp/skr/.claude"
cp "$ga/lib.sh" "$ga/campaign.sh" "$tmp/home/"
echo '{"hooks":"v1"}' >"$tmp/skr/.claude/settings.json"
cat >"$tmp/fake-run" <<'F'
#!/bin/sh
echo "$1-$2-$3" >>"$CALLS"
F
cat >"$tmp/fake-score" <<'F'
#!/bin/sh
mkdir -p "$1"; echo '{"solved": true}' >"$1/score.json"
F
cat >"$tmp/fake-prep" <<'F'
#!/bin/sh
echo "$1" >>"$PREPS"
[ "$1" = "${PREP_FAIL:-}" ] && exit 1
mkdir -p "$GA_ROOT/base/$1"; printf 'cut_compiles=yes\nhidden_fails_on_cut=yes\nhidden_passes_on_head=yes\n' >"$GA_ROOT/base/$1/validation.txt"
F
cat >"$tmp/fake-base" <<'F'
#!/bin/sh
echo b >>"$BASES"; echo '{}' >"$GA_ROOT/head-baseline.json"
F
cat >"$tmp/fake-caf" <<'F'
#!/bin/sh
echo "$*" >>"$CAFS"; exec "$@"
F
chmod +x "$tmp"/fake-*
cenv() { GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_SKREEEP2=$tmp/skr GA_RUN=$tmp/fake-run GA_SCORE=$tmp/fake-score GA_PREPARE=$tmp/fake-prep GA_BASELINE=$tmp/fake-base \
  CALLS=$tmp/calls PREPS=$tmp/preps BASES=$tmp/bases CAFS=$tmp/cafs GA_CAFFEINATED=1 env "$@"; }
prepared() { for t in noise mixer-modes mcu note-ring backpressure scope-view modes midi-synth; do
  mkdir -p "$tmp/root/base/$t"; printf 'cut_compiles=yes\nhidden_fails_on_cut=yes\nhidden_passes_on_head=yes\n' >"$tmp/root/base/$t/validation.txt"; done; echo '{}' >"$tmp/root/head-baseline.json"; }
prepared; rm -rf "$tmp/root/runs/noise-u-1" "$tmp/root/runs/noise-g-1"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1; check "campaign exit 0" "$?" "0"
check "campaign 48 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "48"
check "campaign order" "$(head -3 "$tmp/calls" | tr '\n' ' ')" "noise-g-1 noise-u-1 mixer-modes-g-1 "
check "campaign last" "$(tail -1 "$tmp/calls")" "midi-synth-u-3"
check "campaign log lines" "$(wc -l <"$tmp/root/campaign.log" | tr -d ' ')" "48"
grep -q 'noise-g-1 exit=0 solved=True' "$tmp/root/campaign.log" && ok "campaign log format" || bad "campaign log format"
check "campaign no prepare when ready" "$(cat "$tmp/preps" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "campaign no baseline when cached" "$(cat "$tmp/bases" 2>/dev/null | wc -l | tr -d ' ')" "0"
cmp -s "$tmp/skr/.claude/settings.json" "$tmp/root/gated-settings.json" && ok "campaign snapshots gated settings" || bad "campaign snapshots gated settings"
check "campaign snapshot sha256" "$(cat "$tmp/root/gated-settings.json.sha256" 2>/dev/null)" "$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$tmp/skr/.claude/settings.json")"
echo '{"hooks":"v2"}' >"$tmp/skr/.claude/settings.json"
# resume: noise-g-1 done, noise-u-1 half-run (dir, no score.json)
rm -f "$tmp/calls" "$tmp/root/campaign.log"
rm -rf "$tmp/root/runs"; mkdir -p "$tmp/root/runs/noise-g-1" "$tmp/root/runs/noise-u-1"; echo '{"solved":false}' >"$tmp/root/runs/noise-g-1/score.json"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "campaign resume 47 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "47"
grep -q v1 "$tmp/root/gated-settings.json" && ok "campaign keeps an existing snapshot" || bad "campaign keeps an existing snapshot"
grep -qx 'noise-u-1' "$tmp/calls" && ! grep -qx 'noise-g-1' "$tmp/calls" && ok "campaign resume redoes half-run, skips done" || bad "campaign resume redoes half-run, skips done"
# Ruling 17: errored score.json is not done
cat >"$tmp/fake-score-err" <<'F'
#!/bin/sh
echo "$1" >>"$SCORES"; mkdir -p "$1"; echo '{"solved": false, "error": "scoring incomplete"}' >"$1/score.json"
F
chmod +x "$tmp/fake-score-err"
mkr() { mkdir -p "$tmp/root/runs/$1"; printf '%s\n' "$2" >"$tmp/root/runs/$1/score.json"; [ "${3:-}" = norun ] || echo '{}' >"$tmp/root/runs/$1/run.json"; }
rm -f "$tmp/calls" "$tmp/scores"; rm -rf "$tmp/root/runs" "$tmp/root/campaign.log"
mkr noise-g-1 '{"solved":false,"error":"scoring incomplete"}'
mkr noise-u-1 '{"solved":false,"error":"no result event"}'
mkr mixer-modes-g-1 '{"solved":true,"error":null}'
mkr mixer-modes-u-1 '{"solved":false,"error":"HEAD baseline missing"}' norun
mkr midi-synth-g-1 '{"solved":false,"error":"agent api error: 429 You have hit your weekly limit"}'
mkr mcu-g-1 '{"solved":false,"error":"no result event; agent environment leaked: no init event"}'
cenv SCORES=$tmp/scores $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
grep -qx 'noise-g-1' "$tmp/calls" && bad "retry rescore-only skips run.sh" || ok "retry rescore-only skips run.sh"
grep -q 'noise-g-1' "$tmp/root/campaign.log" && grep 'noise-g-1' "$tmp/root/campaign.log" | grep -q 'retry=rescore' && ok "rescore retry logged" || bad "rescore retry logged"
grep -qx 'noise-u-1' "$tmp/calls" && grep 'noise-u-1' "$tmp/root/campaign.log" | grep -q 'retry=rerun' && ok "no result event reruns the whole run" || bad "no result event reruns the whole run"
grep -qx 'midi-synth-g-1' "$tmp/calls" && grep 'midi-synth-g-1' "$tmp/root/campaign.log" | grep -q 'retry=rerun' && ok "agent api error reruns the whole run" || bad "agent api error reruns the whole run"
grep -qx 'mixer-modes-u-1' "$tmp/calls" && ok "missing run.json reruns the whole run" || bad "missing run.json reruns the whole run"
grep -qx 'mcu-g-1' "$tmp/calls" && grep 'mcu-g-1' "$tmp/root/campaign.log" | grep -q 'retry=rerun' && ok "combined no-result error reruns the whole run" || bad "combined no-result error reruns the whole run"
grep -qx 'mixer-modes-g-1' "$tmp/calls" && bad "error null is skipped" || ok "error null is skipped"
grep -q 'mixer-modes-g-1' "$tmp/root/campaign.log" && bad "skipped run not logged" || ok "skipped run not logged"
# a run that errors again after its retry: exactly one retry, loop continues
rm -f "$tmp/calls" "$tmp/scores"; rm -rf "$tmp/root/runs"
mkr noise-g-1 '{"solved":false,"error":"scoring incomplete"}'
GA_SCORE=$tmp/fake-score-err cenv GA_SCORE=$tmp/fake-score-err SCORES=$tmp/scores $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "errored retry: score.py once for the retried run" "$(grep -c 'noise-g-1$' "$tmp/scores")" "1"
check "errored retry: loop continues to all other runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "47"
# Ruling 27: GA_REPS
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_REPS=2 $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "GA_REPS=2: 16 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "16"
check "GA_REPS=2: order" "$(head -3 "$tmp/calls" | tr '\n' ' ')" "noise-g-2 noise-u-2 mixer-modes-g-2 "
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_REPS=4 $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "GA_REPS=4: 16 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "16"
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_REPS="2 5" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_REPS invalid rep dies" || ok "GA_REPS invalid rep dies"
[ -s "$tmp/calls" ] && bad "GA_REPS invalid: no runs" || ok "GA_REPS invalid: no runs"
# gate ablation: GA_ARMS and GA_TASKS
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_ARMS=t GA_REPS="1 2" GA_TASKS="backpressure mcu mixer-modes scope-view" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "ablation campaign: 8 runs" "$(wc -l <"$tmp/calls" | tr -d ' ')" "8"
check "ablation campaign: order" "$(tr '\n' ' ' <"$tmp/calls")" "backpressure-t-1 mcu-t-1 mixer-modes-t-1 scope-view-t-1 backpressure-t-2 mcu-t-2 mixer-modes-t-2 scope-view-t-2 "
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv GA_ARMS="g x" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_ARMS invalid arm dies" || ok "GA_ARMS invalid arm dies"
[ -s "$tmp/calls" ] && bad "GA_ARMS invalid: no runs" || ok "GA_ARMS invalid: no runs"
cenv GA_ARMS=" " $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_ARMS empty dies" || ok "GA_ARMS empty dies"
cenv GA_TASKS="mcu nosuch" $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_TASKS unknown task dies" || ok "GA_TASKS unknown task dies"
[ -s "$tmp/calls" ] && bad "GA_TASKS invalid: no runs" || ok "GA_TASKS invalid: no runs"
cenv GA_TASKS=" " $SH "$tmp/home/campaign.sh" >/dev/null 2>&1 && bad "GA_TASKS empty dies" || ok "GA_TASKS empty dies"
# smoke
rm -f "$tmp/calls"; rm -rf "$tmp/root/runs"
cenv $SH "$tmp/home/campaign.sh" --smoke >/dev/null 2>&1
check "campaign smoke" "$(tr '\n' ' ' <"$tmp/calls")" "midi-synth-g-9 midi-synth-u-9 "
# preflight: unlock, prepare only missing/invalid, baseline when missing
rm -f "$tmp/calls" "$tmp/preps" "$tmp/bases"; rm -rf "$tmp/root/runs" "$tmp/root/head-baseline.json"; mkdir -p "$tmp/root/runs"
rm -rf "$tmp/root/base/mcu"
printf 'cut_compiles=yes\nhidden_fails_on_cut=no\nhidden_passes_on_head=yes\n' >"$tmp/root/base/noise/validation.txt"
printf 'cut_compiles=yes\nhidden_fails_on_cut=yes\nhidden_passes_on_head=yes\ngate_visible_on_cut=yes\n' >"$tmp/root/base/modes/validation.txt"
printf 'cut_compiles=yes\nhidden_fails_on_cut=yes\nhidden_passes_on_head=yes\ngate_visible_on_cut=no\n' >"$tmp/root/base/note-ring/validation.txt"
chmod 000 "$tmp/root/base"
cenv $SH "$tmp/home/campaign.sh" >/dev/null 2>&1
check "preflight unlocked base" "$(ls "$tmp/root/base" >/dev/null 2>&1; echo $?)" "0"
check "preflight prepares missing and failed only" "$(sort "$tmp/preps" | tr '\n' ' ')" "mcu noise note-ring "
check "preflight baseline once" "$(wc -l <"$tmp/bases" | tr -d ' ')" "1"
check "preflight then runs all" "$(wc -l <"$tmp/calls" | tr -d ' ')" "48"
# smoke preflight touches midi-synth only
rm -f "$tmp/calls" "$tmp/preps"; rm -rf "$tmp/root/runs" "$tmp/root/base/midi-synth" "$tmp/root/base/noise"
cenv $SH "$tmp/home/campaign.sh" --smoke >/dev/null 2>&1
check "smoke preflight only midi-synth" "$(tr '\n' ' ' <"$tmp/preps")" "midi-synth "
# abort when prepare still fails: no runs
rm -f "$tmp/calls" "$tmp/preps"; rm -rf "$tmp/root/runs" "$tmp/root/base/mcu"
cenv PREP_FAIL=mcu $SH "$tmp/home/campaign.sh" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$tmp/calls" ] && ok "preflight aborts before any run" || bad "preflight aborts before any run" "rc=$rc"
# caffeinate wrapper: re-exec once, marker prevents loops
rm -f "$tmp/calls" "$tmp/cafs"; rm -rf "$tmp/root/runs"; mkdir -p "$tmp/root/base/mcu"; cp "$tmp/root/base/noise/validation.txt" "$tmp/root/base/mcu/" 2>/dev/null
prepared
GA_HOME=$tmp/home GA_ROOT=$tmp/root GA_RUN=$tmp/fake-run GA_SCORE=$tmp/fake-score GA_PREPARE=$tmp/fake-prep GA_BASELINE=$tmp/fake-base \
  CALLS=$tmp/calls PREPS=$tmp/preps BASES=$tmp/bases CAFS=$tmp/cafs GA_CAFFEINATE="$tmp/fake-caf" $SH "$tmp/home/campaign.sh" --smoke >/dev/null 2>&1
check "campaign re-execs under caffeinate once" "$(wc -l <"$tmp/cafs" | tr -d ' ')" "1"
check "campaign under caffeinate ran smoke" "$(tr '\n' ' ' <"$tmp/calls")" "midi-synth-g-9 midi-synth-u-9 "
chmod -R 755 "$tmp/root" 2>/dev/null
rm -rf "$tmp"

# --- ga_install_engine
r=$(mktemp -d); ( cd "$r" && git init -q && mkdir .dsh && printf 'build.mill\tbuild\n' > .dsh/frozen-paths && echo x > f && git add -A && git -c user.name=t -c user.email=t@l commit -qm b )
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' safety" >/dev/null 2>&1; check "install engine exit" "$?" "0"
check "engine vendored" "$([ -f "$r/.dsh/engine/gate.sh" ] && echo y)" "y"
check "mode safety" "$(awk -F'\t' '$1=="mode"{print $2}' "$r/.dsh/policy/turn-end.tsv" 2>/dev/null)" "safety"
check "mode frozen" "$(grep -c '^\.dsh/policy/turn-end\.tsv	' "$r/.dsh/frozen-paths")" "1"
check "install committed" "$(git -C "$r" status --porcelain | wc -l | tr -d ' ')" "0"
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' full" >/dev/null 2>&1
check "mode full replaces" "$(awk -F'\t' '$1=="mode"{print $2}' "$r/.dsh/policy/turn-end.tsv" 2>/dev/null)" "full"
check "frozen row once" "$(grep -c '^\.dsh/policy/turn-end\.tsv	' "$r/.dsh/frozen-paths")" "1"
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; ga_install_engine '$r' fast" >/dev/null 2>&1; check "install rejects mode fast" "$?" "1"
rm -rf "$r"

# --- prepare.sh: reference patch that does not apply
fr=$(mktemp -d); mkdir -p "$fr/tasks/fr-x/hidden/a" "$fr/head"
printf "TASK_MODULE='a.test'\nHIDDEN_SPEC='a/S.scala'\nHIDDEN_SPEC_SRC='hidden/a/S.scala'\nCUT_FILES=''\nREFERENCE_PATCH='reference.patch'\nFEATURE='x'\n" > "$fr/tasks/fr-x/task.env"
echo 'object S extends Suite' > "$fr/tasks/fr-x/hidden/a/S.scala"
printf -- '--- a/nope.scala\n+++ b/nope.scala\n@@ -1 +1 @@\n-a\n+b\n' > "$fr/tasks/fr-x/reference.patch"
out=$($SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; GA_HOME='$fr'; REFERENCE_PATCH=reference.patch; ga_check_patch fr-x '$fr/head'" 2>&1); rc=$?
check "non-applying reference patch refused" "$rc" "1"
case $out in *"does not apply"*) ok "patch refusal names the cause" ;; *) bad "patch refusal names the cause" "$out" ;; esac
echo a > "$fr/head/nope.scala"
$SH -c "GA_LIB_PATH='$ga/lib.sh'; . '$ga/lib.sh'; GA_HOME='$fr'; REFERENCE_PATCH=reference.patch; ga_check_patch fr-x '$fr/head'" >/dev/null 2>&1
check "applying reference patch accepted" "$?" "0"
rm -rf "$fr"

echo "shell-test: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
