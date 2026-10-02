#!/bin/sh
# HoldoutModule (kit/recipes/mill/Gate.mill) takes its sources only from DSH_HOLDOUT_DIR. A real Mill 1.1.8 scratch
# build proves it: (a) unset -> zero tests, success; (b) a passing test runs; (c) a failing test is reported.
# Needs `mill` on PATH and the network (coursier); SKIPs (exit 0) without mill. Kills nothing: --no-daemon only.
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tpl=$(CDPATH= cd -- "$engine/../.." && pwd)
command -v mill >/dev/null 2>&1 || { echo "SKIP holdout-module-test: no mill on PATH"; exit 0; }
passed=0; failed=0
ok() { passed=$((passed+1)); echo "ok   $1"; }
bad() { failed=$((failed+1)); echo "FAIL $1"; printf '%s\n' "$2" | tail -15; }
w=$(mktemp -d) && h=$(mktemp -d) || exit 1
trap 'rm -rf "$w" "$h"' EXIT
mkdir -p "$w/buildKit"
printf '1.1.8\n' > "$w/.mill-version"
printf 'package build.buildKit\n' > "$w/buildKit/package.mill"
cp "$tpl/kit/recipes/mill/Gate.mill" "$w/buildKit/Gate.mill"
cat > "$w/build.mill" <<'M'
//| mvnDeps:
//| - com.goyeau::mill-scalafix::0.6.2
package build

import mill._
import mill.scalalib._
import build.buildKit.HoldoutModule

object BuildPaths {
  val repoRoot: os.Path = mill.api.BuildCtx.workspaceRoot
}

object m extends ScalaModule {
  def scalaVersion = "3.8.4"
  object test extends ScalaTests with TestModule.Munit with HoldoutModule {
    def mvnDeps = Seq(mvn"org.scalameta::munit:1.0.4")
  }
}
M

# A file in the module's default test src dir must never run, set or unset.
mkdir -p "$w/m/test/src"
cat > "$w/m/test/src/InRepo.scala" <<'S'
class InRepoSuite extends munit.FunSuite:
  test("in-repo test")(assertEquals(1, 1))
S

# (a) unset: no sources, success
out=$(cd "$w" && env -u DSH_HOLDOUT_DIR mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -5
[ $rc -eq 0 ] && ok "unset: m.test succeeds" || bad "unset: m.test succeeds" "$out"
printf '%s' "$out" | grep -q 'MyHoldout\|in-repo test' && bad "unset: no tests ran" "$out" || ok "unset: no tests ran"

# (b) one passing test
cat > "$h/Pass.scala" <<'S'
class MyHoldoutPass extends munit.FunSuite:
  test("holdout passes")(assertEquals(1 + 1, 2))
S
out=$(cd "$w" && DSH_HOLDOUT_DIR="$h" mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -8
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -q 'holdout passes'; then ok "set + passing test: runs and passes"; else bad "set + passing test: runs and passes" "$out"; fi

# (c) add a failing test
cat > "$h/Fail.scala" <<'S'
class MyHoldoutFail extends munit.FunSuite:
  test("holdout fails")(assertEquals(1 + 1, 3))
S
out=$(cd "$w" && DSH_HOLDOUT_DIR="$h" mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -12
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'holdout fails'; then ok "set + failing test: failure reported"; else bad "set + failing test: failure reported" "$out"; fi

printf '%s' "$out" | grep -q 'in-repo test' && bad "set: in-repo test never runs" "$out" || ok "set: in-repo test never runs"

# set -> unset again: zero tests
out=$(cd "$w" && env -u DSH_HOLDOUT_DIR mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -4
if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q 'MyHoldout\|in-repo test'; then ok "set then unset: zero tests again"; else bad "set then unset: zero tests again" "$out"; fi

# relative value and missing dir fail
out=$(cd "$w" && DSH_HOLDOUT_DIR=relative/dir mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -4
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'must be an absolute path'; then ok "relative value fails"; else bad "relative value fails" "$out"; fi
out=$(cd "$w" && DSH_HOLDOUT_DIR="$h/nope" mill --no-daemon m.test 2>&1); rc=$?
echo "$out" | tail -4
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -q 'does not name an existing directory'; then ok "missing dir fails"; else bad "missing dir fails" "$out"; fi

echo "holdout-module-test: $passed passed, $failed failed"
[ $failed -eq 0 ]
