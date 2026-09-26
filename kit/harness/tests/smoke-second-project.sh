#!/bin/sh
# Second-project smoke (spec 2026-09-26): a scratch Mill project assembled from kit/recipes/mill.md's own
# text (§1's head, §3's plumbing, §7's gate tasks) plus kit/recipes/mill/Gate.mill is gated end to end by
# an engine vendored with install.sh -- health, semantic-guard, turn-end, preCommit -- then an sbt scratch
# stands down by name, and Setup.scala's install-harness step vendors the engine into a fresh directory.
#
# Needs real Mill (the global `mill` the recipe's ./mill wrapper execs), the network (coursier) and
# scala-cli, so it is deliberately NOT named *-test.sh: check-harness's discovery must not pick it up.
#   sh kit/harness/tests/smoke-second-project.sh        # exits 0 iff every assertion holds
# SMOKE_KEEP=1 keeps the scratch directories for inspection. A SKIP line names what was not checked.
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tpl=$(CDPATH= cd -- "$engine/../.." && pwd)
recipe="$tpl/kit/recipes/mill.md"
passed=0; failed=0; skipped=0
is() { if [ "$2" = "$3" ]; then passed=$((passed+1)); printf 'ok   %s\n' "$1"; else failed=$((failed+1)); printf 'FAIL %s\n     want [%s]\n     got  [%s]\n' "$1" "$2" "$3"; fi; }
skip() { skipped=$((skipped+1)); printf 'SKIP %s\n' "$1"; }
yn() { if "$@"; then echo yes; else echo no; fi; }
say() { printf '# %s\n' "$*"; }
has() { printf '%s\n' "$1" | grep -Eq "$2"; }
hasF() { printf '%s\n' "$1" | grep -qF "$2"; }
# turn-end turns any status other than 0/2 into exit 0 with this line, so exit 0 alone cannot tell a gate that
# checked from one that crashed.
crashed='the gate itself failed'

real_mill=$(command -v mill 2>/dev/null) || { printf 'smoke: no global mill on PATH -- the recipe wrapper execs one\n' >&2; exit 1; }
command -v scala-cli >/dev/null 2>&1 || { printf 'smoke: scala-cli not on PATH\n' >&2; exit 1; }

scratches=""
cleanup() {
  for d in $scratches; do
    [ -x "$d/mill" ] && [ -d "$d/out" ] && (cd "$d" && ./mill shutdown >/dev/null 2>&1)
    if [ "${SMOKE_KEEP:-0}" = 1 ]; then printf '# kept %s\n' "$d"; else rm -rf "$d"; fi
  done
}
trap cleanup EXIT
# Called as `x=$(newdir)`, a subshell, so the caller records the directory: `track "$x"`.
newdir() { _d=$(mktemp -d) && CDPATH= cd -P -- "$_d" && pwd; }
track() { scratches="$scratches $1"; }

# The body of the first ```scala fence under the `## <n>.` heading.
fence() { awk -v h="## $1." '
  index($0, h) == 1 { in_sec = 1; next }
  in_sec && /^## / { exit }
  in_sec && !in_fence && /^```scala/ { in_fence = 1; next }
  in_fence && /^```/ { exit }
  in_fence { print }' "$recipe"; }

git_q() { git -C "$w" -c user.name=smoke -c user.email=smoke@example.invalid "$@"; }

# --- 1-2. assemble the scratch Mill project from the recipe's text ----------------------------------------
w=$(newdir); track "$w"
say "scratch Mill project: $w"
git -C "$w" init -q
{ fence 1; printf '\n'; fence 7; printf '\nobject core extends Formattable with GateLayer { def scalaVersion = "3.8.4" }\n'; } > "$w/build.mill"
is "recipe: §1 head starts with the //| header" "//| mvnDeps:" "$(head -1 "$w/build.mill")"
is "recipe: §7 fragment present" yes "$(yn grep -q '^def moduleMap() = Task.Command' "$w/build.mill")"
fence 3 > "$w/ScalafixExtra.mill"
is "recipe: §3 plumbing present" yes "$(yn grep -q '^trait ExtraScalafixRules' "$w/ScalafixExtra.mill")"
mkdir -p "$w/buildKit" "$w/core/src" "$w/scripts"
printf 'package build.buildKit\n' > "$w/buildKit/package.mill"
cp "$tpl/kit/recipes/mill/Gate.mill" "$w/buildKit/Gate.mill"
cp "$tpl/kit/recipes/mill/ArchitectureShapeModule.mill" "$w/buildKit/ArchitectureShapeModule.mill"
printf '1.1.8\n' > "$w/.mill-version"
git -C /Users/viktorskalinins/IdeaProjects/skreeep2 show master:mill > "$w/mill" 2>/dev/null || {
  printf '#!/usr/bin/env bash\nexec mill "$@"\n' > "$w/mill"; say "skreeep2 wrapper unavailable; plain exec wrapper used"; }
chmod +x "$w/mill"
# One rule at least: `core` mixes GateLayer but not ArchitectureShapeModule, so nothing adds AllowedShape, and
# scalafix answers an empty ruleset with `No rules requested to run` (a fix --check failure), per recipe §7.
printf 'rules = [DisableSyntax]\n' > "$w/.scalafix.conf"
printf 'version = "3.10.7"\nrunner.dialect = scala3\n' > "$w/.scalafmt.conf"
printf 'out/\n.bsp/\n.scala-semantic/\n.dsh/.state/\n' > "$w/.gitignore"
printf 'package a\nobject A { val x: Int = 1 }\n' > "$w/core/src/A.scala"
printf 'object Tool\n' > "$w/scripts/Tool.scala"
git_q add -A && git_q commit -q -m "scratch: assembled from the recipe"

# --- 3. install ----------------------------------------------------------------------------------------------
out=$(sh "$engine/install.sh" "$w" 2>&1); code=$?
is "install: exit" 0 "$code"
is "install: STAMP" yes "$(yn test -f "$w/.dsh/engine/STAMP")"
git_q add -A && git_q commit -q -m "harness installed"

# PATH-first logger: ./mill execs `mill`, which this shim records before exec'ing the real one.
bin=$(newdir); track "$bin"; log="$bin/mill-calls.log"; : > "$log"
printf '#!/bin/sh\nprintf "mill %%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$log" "$real_mill" > "$bin/mill"
chmod +x "$bin/mill"
PATH="$bin:$PATH"; export PATH

m() { (cd "$w" && ./mill --no-server --ticker false "$@"); }
gate() { _sub=$1; shift; CLAUDE_PROJECT_DIR="$w" GATE_ROOT="$w" sh "$w/.dsh/engine/gate.sh" "$_sub"; }
start='{"session_id":"s1","hook_event_name":"SessionStart"}'
stop='{"session_id":"s1","hook_event_name":"Stop"}'
read_a="{\"tool_name\":\"read\",\"tool_input\":{\"file_path\":\"$w/core/src/A.scala\"}}"

# --- 4. moduleMap ------------------------------------------------------------------------------------------------
say "mill moduleMap (first run resolves the build; minutes on a cold cache)"
mm=$(m moduleMap 2>"$bin/moduleMap.err"); code=$?
is "moduleMap: exit" 0 "$code"
[ "$code" = 0 ] || tail -20 "$bin/moduleMap.err"
# §1's scalafixRules is a JavaModule outside the four lists, so Gate.moduleMapRows gives it a row with no
# capabilities (every compilable module is mapped); core has fmt and scalafix, and no tests (no test module).
is "moduleMap: core row, no tests capability" "$(printf 'core\tcore\tfmt,scalafix')" "$(printf '%s\n' "$mm" | awk -F'\t' '$1 == "core"')"
is "moduleMap: exactly core and scalafixRules" "$(printf 'core\tcore\tfmt,scalafix\nscalafixRules\tscalafixRules\t')" "$mm"

# --- 5. health --------------------------------------------------------------------------------------------------
# Mill takes several tasks only with `+` between them: without it the second name is an argument to the first.
say "mill core.compile + core.semanticDbData + scalaSemanticWriteClasspath"
m core.compile + core.semanticDbData + scalaSemanticWriteClasspath > "$bin/compile.out" 2>&1; code=$?
is "compile + semanticDbData + classpath: exit" 0 "$code"
is "compile: a SemanticDB index exists" yes "$(yn test -n "$(find "$w/out/core" -path '*/META-INF/semanticdb/core/src/A.scala.semanticdb' 2>/dev/null | head -1)")"
[ "$code" = 0 ] || tail -20 "$bin/compile.out"
if [ -x "$HOME/.local/bin/scalasemantic-mcp" ] || [ -n "${SCALASEMANTIC_MCP_LAUNCHER:-}" ]; then
  out=$(printf '%s' "$start" | gate health 2>&1); code=$?
  is "health: exit" 0 "$code"
  is "health: healthy=1" yes "$(yn grep -qx 'healthy=1' "$w/.dsh/.state/health")"
  [ -f "$w/.dsh/.state/health" ] && grep -qx 'healthy=1' "$w/.dsh/.state/health" || { printf '%s\n' "$out" | tail -10; cat "$w/.dsh/.state/health" 2>/dev/null; }

  # --- 6. semantic-guard denies a covered read ---------------------------------------------------------------
  out=$(printf '%s' "$read_a" | gate semantic-guard 2>&1); code=$?
  is "semantic-guard: covered read denied" 2 "$code"
else
  skip "health: healthy=1 (no ~/.local/bin/scalasemantic-mcp launcher on this machine)"
  skip "semantic-guard: covered read denied (depends on healthy=1)"
fi

# --- 7. unhealthy: the same read stands down --------------------------------------------------------------------
out=$(printf '%s' "$start" | SCALASEMANTIC_MCP_LAUNCHER=/nonexistent gate health 2>&1)
is "health (no launcher): healthy=0" yes "$(yn grep -qx 'healthy=0' "$w/.dsh/.state/health")"
out=$(printf '%s' "$read_a" | gate semantic-guard 2>&1); code=$?
is "semantic-guard (unhealthy): exit" 0 "$code"
is "semantic-guard (unhealthy): stands down" yes "$(yn has "$out" 'stands down|standing down')"
[ "$code" = 0 ] || printf '%s\n' "$out" | tail -5

# --- 8. turn-end over a real edit to a mapped module ------------------------------------------------------------
printf '%s' "$start" | gate baseline >/dev/null 2>&1
printf 'package a\nobject A { val x: Int = 1; val y: Int = 2 }\n' > "$w/core/src/A.scala"
say "turn-end over core/src/A.scala (real Mill checks)"
: > "$log"
out=$(printf '%s' "$stop" | gate turn-end 2>&1); code=$?
is "turn-end (mapped edit): exit" 0 "$code"
is "turn-end (mapped edit): the gate did not crash" no "$(yn hasF "$out" "$crashed")"
[ "$code" = 0 ] || printf '%s\n' "$out" | tail -25
is "turn-end (mapped edit): no test claim" no "$(yn has "$out" '[Tt][Ee][Ss][Tt][Ss]? ([Pp][Aa][Ss][Ss]|[Rr][Aa][Nn]|[Rr][Uu][Nn])')"
is "turn-end (mapped edit): ran core's checks" yes "$(yn grep -q 'core\.' "$log")"

# --- 9. turn-end over an unmapped .scala path only (the unmapped-path ruling) -----------------------------------
git_q checkout -q -- core/src/A.scala
printf '%s' '{"session_id":"s2","hook_event_name":"SessionStart"}' | gate baseline >/dev/null 2>&1
printf 'object Tool { val z = 3 }\n' > "$w/scripts/Tool.scala"
: > "$log"
out=$(printf '%s' '{"session_id":"s2","hook_event_name":"Stop"}' | gate turn-end 2>&1); code=$?
is "turn-end (unmapped only): exit" 0 "$code"
is "turn-end (unmapped only): the gate did not crash" no "$(yn hasF "$out" "$crashed")"
[ "$code" = 0 ] || printf '%s\n' "$out" | tail -15
is "turn-end (unmapped only): no Mill task beyond moduleMap" "" "$(grep -v ' moduleMap *$' "$log")"
git_q checkout -q -- scripts/Tool.scala

# --- 10. preCommit -----------------------------------------------------------------------------------------------
say "mill -j 1 preCommit"
m -j 1 preCommit > "$bin/preCommit.out" 2>&1; code=$?
is "preCommit: exit" 0 "$code"
[ "$code" = 0 ] || tail -25 "$bin/preCommit.out"

# --- 11. an sbt project stands down by name -----------------------------------------------------------------------
s=$(newdir); track "$s"
git -C "$s" init -q
mkdir -p "$s/src"
printf 'scalaVersion := "3.8.4"\n' > "$s/build.sbt"
printf 'object A\n' > "$s/src/A.scala"
git -C "$s" add -A && git -C "$s" -c user.name=smoke -c user.email=smoke@example.invalid commit -q -m sbt
out=$(sh "$engine/install.sh" "$s" 2>&1); code=$?
is "sbt: install exit" 0 "$code"
git -C "$s" add -A && git -C "$s" -c user.name=smoke -c user.email=smoke@example.invalid commit -q -m harness
note='gate engine supports Mill builds only; found: build.sbt'
out=$(printf '%s' "$start" | CLAUDE_PROJECT_DIR="$s" GATE_ROOT="$s" sh "$s/.dsh/engine/gate.sh" health 2>&1)
is "sbt: health names the stand-down" yes "$(yn hasF "$out" "$note")"
printf '%s' "$start" | CLAUDE_PROJECT_DIR="$s" GATE_ROOT="$s" sh "$s/.dsh/engine/gate.sh" baseline >/dev/null 2>&1
printf 'object A { val x = 1 }\n' > "$s/src/A.scala"
out=$(printf '%s' "$stop" | CLAUDE_PROJECT_DIR="$s" GATE_ROOT="$s" sh "$s/.dsh/engine/gate.sh" turn-end 2>&1); code=$?
is "sbt: dirty Stop exit" 0 "$code"
is "sbt: dirty Stop: the gate did not crash" no "$(yn hasF "$out" "$crashed")"
is "sbt: dirty Stop names the stand-down" yes "$(yn hasF "$out" "$note")"

# --- 12. Setup.scala end to end ----------------------------------------------------------------------------------
# install-harness runs after install-kit and before any step that initialises git, so the fresh target is a
# git repository first (Setup's own StageGitChanges is the last step).
if [ "${SMOKE_SKIP_SETUP:-0}" = 1 ]; then
  skip "setup: install-harness completed (SMOKE_SKIP_SETUP=1)"
else
  f=$(newdir); track "$f"
  git -C "$f" init -q
  say "scala-cli run Setup.scala into $f (many minutes)"
  # Agent mode answers `need-input` (exit 2) until every question has an answer, so the rest are given their
  # defaults; scala-version is the recipe's measured 3.8.4 rather than Maven Central's latest.
  answers='{"kit":"yes","build-tool":"mill","scala-version":"3.8.4","cross-version":"no","scripts":"none","github-flow":"no","sdkmanrc":"no","ecosystem":"none","web-server":"no","web-client":"no","db-access":"no","serverless-run":"no","api-docs":"no","logging":"no","test-tools":"none","stainless":"no","stryker":"no","performance-testing":"no","scoverage":"no","optics":"no","dto-mapping":"no","config-loader":"no","mcp-tools":"no","mdoc":"no","git-hooks":"no","version-bump":"no","docker":"no"}'
  (cd "$tpl" && scala-cli run Setup.scala --server=false -- --agent --answers "$answers" "$f") \
    > "$bin/setup.json" 2> "$bin/setup.err"; code=$?
  is "setup: exit" 0 "$code"
  st=$(tr -d '\n' < "$bin/setup.json" | grep -o '"id" *: *"install-harness" *, *"status" *: *"[a-z]*"' | sed 's/.*"\([a-z]*\)"$/\1/')
  is "setup: install-harness completed" completed "$st"
  is "setup: .dsh/engine/STAMP" yes "$(yn test -f "$f/.dsh/engine/STAMP")"
  if [ "$st" != completed ] || [ "$code" != 0 ]; then
    tail -20 "$bin/setup.err"; grep -o '"id" *: *"install-harness"[^}]*' "$bin/setup.json"
    grep -q '"need-input"' "$bin/setup.json" && printf '# setup still needs: %s\n' "$(grep -o '"id":"[^"]*"' "$bin/setup.json" | tr '\n' ' ')"
  fi
  [ -n "${SMOKE_SETUP_JSON:-}" ] && cp "$bin/setup.json" "$SMOKE_SETUP_JSON"
fi

printf '%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" = 0 ]
