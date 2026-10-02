#!/bin/sh
# Direct tests for .dsh/engine/module-map.sh — which Mill module owns a changed source path, which checks
# that module has, and when the lookup is allowed to answer at all. `module-map.sh` is a lookup, not a
# gate: it takes a path argument and prints `<module id>` TAB `<capabilities>`, or `-`, so it does not
# fit the payload fixture runner (`tests/run.sh` drives `gate.sh` through a subcommand plus a JSON
# payload and can compare only an exit code and one grep). Like `lib-test.sh` and `health-test.sh`,
# this file is deliberately NOT wired into `run.sh`.
#
# The contract under test:
#   0 + `<id>` TAB `<capabilities>`  the map owns the path, with the checks it may run
#   0 + `-`                          the map is present and no module owns the path
#   3 + one line on stderr           cannot decide: no map, or a rebuild that failed or was refused.
#                                    Never a silent `-` — Task 8 must block on this instead of skipping.
#
# The capability vocabulary is `fmt` (the module is in `mainModules`, what `preCommit` reformats),
# `scalafix` (it is in `scalafixModules`) and `tests` (it has a test submodule named `test` in the
# compile set, so `<id>.test.compile` resolves), in that order, comma-separated. `compile` exists for
# every row, so an empty capability string means "compile only" and nothing more.
#
# The lookup is run with the interpreter that is running this test, never with a hardcoded `sh`, so
# `dash .dsh/engine/tests/module-map-test.sh` exercises the script under dash and `sh …` under /bin/sh. The
# script's executable bit is not relied on (it stays 755 for humans); the interpreter is explicit, and
# the choice is printed below and asserted against the running shell.
#
# No real Mill runs. The scratch root carries its own `./mill` stub whose map differs from the cached
# one in both an id (`engine/details` renamed) and a capability (`engine/shape` loses `tests`), so
# "answered from the cache" and "answered from a refresh" differ by the answer itself, not only by
# whether the stub was called. mtimes are set with `touch -t` because `module-map.sh` compares them
# with `-nt`, which has one-second resolution.
#
# Run: sh .dsh/engine/tests/module-map-test.sh   (and: dash .dsh/engine/tests/module-map-test.sh)
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dsh="$engine/module-map.sh"
tab=$(printf '\t')
passed=0
failed=0

ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
is() { # is <name> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: wanted [$2], got [$3]"; fi
}

# The interpreter running this test, so the script is exercised under it too. `ps -o comm=` names a
# bare word on macOS and a PATH on Linux (and nothing at all in some containers), so BOTH sides of
# the comparison below are normalised to a basename — the same normalisation run.sh applies to its
# own assertion (M2). Comparing a `ps` path against a `command -v` path is what makes this flaky:
# measured on a `ps -o comm=` that prints `/bin/dash`, the un-normalised form gave 44 passed /
# 1 failed while the code under test was correct.
runner=$(ps -p $$ -o comm= 2>/dev/null | tr -d ' ')
case "$runner" in
  */*) runner=$(basename -- "$runner") ;;
esac
[ -n "$runner" ] || runner=sh
shell_bin=$(command -v "$runner" 2>/dev/null) || shell_bin=""
[ -n "$shell_bin" ] || shell_bin=$runner
printf '# lookup interpreter: %s (this test runs under %s)\n' "$shell_bin" "$runner"
is "the lookup runs under the invoking shell" "$runner" "$(basename -- "$shell_bin")"

scratch=$(mktemp -d)
linkdir=$(mktemp -d)
mkdir -p "$scratch/.dsh/.state" "$scratch/engine/shape/src" "$scratch/engine/shape/test/src" \
  "$scratch/engine/details/src" "$scratch/wiring/arhitecture/src" "$scratch/scope/src" \
  "$scratch/scope/test/src" "$scratch/bench/src" "$scratch/bench/test/src" \
  "$scratch/backend/api/src" "$scratch/scalafixRules/src" "$scratch/docs"
# A root reached through a symlink, and a symlinked spelling of a path inside the root: both must
# resolve to the same physical path, or the lookup answers `-` for a file a module owns.
ln -s "$scratch" "$linkdir/root"
map="$scratch/.dsh/.state/modules.tsv"

# The cached map: a parent with two children, a non-Layer `Common` that owns tests, a test module
# that is a `Common` (so it owns its own row, which must win over its parent), a module the build
# scalafixes without formatting (`scalafix` alone — the shape list-derived capabilities produce),
# and a bare `ScalaModule` with no capabilities at all (third column present but empty).
seed_map() {
  {
    printf 'engine\tengine\tfmt,scalafix\n'
    printf 'engine/shape\tengine.shape\tfmt,scalafix,tests\n'
    printf 'engine/details\tengine.details\tfmt,scalafix,tests\n'
    printf 'wiring/arhitecture\twiring.arhitecture\tfmt,scalafix,tests\n'
    printf 'scope\tscope\tfmt,tests\n'
    printf 'bench\tbench\tfmt,scalafix,tests\n'
    printf 'bench/test\tbench.test\tfmt\n'
    printf 'scalafixRules\tscalafixRules\t\n'
    printf 'backend/api\tbackend.api\tscalafix\n'
  } > "$map"
}
seed_map

# The stub Mill: records how it was called, then prints the *refreshed* map. STUB_TICKER=1 makes it
# print what a ticker-enabled Mill prints instead — every line prefixed with `<n>] `, the first with
# the task name as well — STUB_BAD=1 prints a capability token that is not in the vocabulary, and
# STUB_NO_TAB=1 drops a row's third column. All three shapes must be refused rather than installed:
# capabilities are what the gate is allowed to run, so a row missing that statement is not "no
# capabilities", it is a row that would silently stop the checks the module actually has.
cat > "$scratch/mill" <<'STUB'
#!/bin/sh
printf 'mill %s\n' "$*" >> "$STUB_LOG"
[ "${STUB_EXIT:-0}" = 0 ] || exit "${STUB_EXIT}"
if [ "${STUB_TICKER:-0}" = 1 ]; then
  printf '1] moduleMap engine\tengine\tfmt,scalafix\n'
  printf '1] engine/shape\tengine.shape\tfmt,scalafix,tests\n'
  printf '1] engine/details\tengine.renamed\tfmt,scalafix\n'
  printf '1] scope\tscope\tfmt\n'
  exit 0
fi
if [ "${STUB_BAD:-0}" = 1 ]; then
  printf 'engine\tengine\tscalafixx\n'
  exit 0
fi
if [ "${STUB_NO_TAB:-0}" = 1 ]; then
  printf 'engine\tengine\tfmt,scalafix\n'
  printf 'engine/shape\tengine.shape\n'
  exit 0
fi
printf 'engine\tengine\tfmt,scalafix\n'
printf 'engine/shape\tengine.shape\tfmt,scalafix\n'
printf 'engine/details\tengine.renamed\tfmt,scalafix\n'
printf 'wiring/arhitecture\twiring.arhitecture\tfmt,scalafix,tests\n'
printf 'scope\tscope\tfmt,tests\n'
printf 'bench\tbench\tfmt,scalafix,tests\n'
printf 'bench/test\tbench.test\tfmt\n'
printf 'scalafixRules\tscalafixRules\t\n'
printf 'backend/api\tbackend.api\tscalafix\n'
STUB
chmod +x "$scratch/mill"
log="$scratch/mill.log"

# capture <path> [env assignments…]: runs the lookup with this test's interpreter and records `out`,
# `code` and `err` (the last as one string, to check the reason line).
capture() {
  cpath=$1
  shift
  errfile=$(mktemp)
  out=$(env "$@" GATE_ROOT="$scratch" STUB_LOG="$log" "$shell_bin" "$dsh" "$cpath" 2>"$errfile")
  code=$?
  err=$(cat "$errfile")
  rm -f "$errfile"
}

check() { # check <name> <path> <want stdout>
  capture "$2"
  is "$1" "$3" "$out"
}
check_status() { # check_status <name> <path> <want exit code>
  capture "$2"
  is "$1" "$3" "$code"
}
cannot_decide() { # cannot_decide <name> <path> [env…] — exit 3, no stdout, a one-line reason
  cname=$1
  cpath=$2
  shift 2
  capture "$cpath" "$@"
  is "$cname: exit" "3" "$code"
  is "$cname: stdout" "" "$out"
  case "$err" in
    "") bad "$cname: no reason on stderr" ;;
    *"
"*) bad "$cname: the reason is not one line: [$err]" ;;
    *) ok "$cname: a one-line reason on stderr" ;;
  esac
}

# --- the cached map, fresh (build.mill older than it): no Mill run, longest prefix wins ---------
touch -t 202001010000 "$scratch/build.mill"
touch -t 203001010000 "$map"
: > "$log"

check "a module reports its own capabilities" "$scratch/engine/Topology.scala" "engine${tab}fmt,scalafix"
check "a nested module beats its parent" "$scratch/engine/shape/src/Host.scala" "engine.shape${tab}fmt,scalafix,tests"
check "the parent's other child is not shadowed" "$scratch/engine/details/src/Wiring.scala" "engine.details${tab}fmt,scalafix,tests"
check "a sibling subtree is not shadowed" "$scratch/wiring/arhitecture/src/Wiring.scala" "wiring.arhitecture${tab}fmt,scalafix,tests"
check "a non-Layer Common is mapped without scalafix" "$scratch/scope/src/View.scala" "scope${tab}fmt,tests"
check "a test path resolves to the module that owns it" "$scratch/scope/test/src/ViewSpec.scala" "scope${tab}fmt,tests"
check "a test module that is a Common owns its own row" "$scratch/bench/test/src/BenchSpec.scala" "bench.test${tab}fmt"
check "a compile-only module has empty capabilities" "$scratch/scalafixRules/src/AllowedShape.scala" "scalafixRules${tab}"
check "a module the build does not format keeps scalafix only" "$scratch/backend/api/src/TopologyBackend.scala" "backend.api${tab}scalafix"
check "an unknown path inside the root yields -" "$scratch/docs/notes.md" "-"
check "a path outside the root yields -" "/etc/hosts" "-"
check_status "an unowned path is an answer, not a failure" "$scratch/docs/notes.md" "0"
is "a fresh cache is not refreshed" "" "$(cat "$log")"

# --- a root, or a path inside it, reached through a symlink still resolves to the same module ----
# `pwd` is logical in dash and in bash, so both sides are resolved physically or a caller spelling
# either one differently gets `-` for a file a module owns — a silent skip.
errfile=$(mktemp)
link_out=$(GATE_ROOT="$linkdir/root" STUB_LOG="$log" "$shell_bin" "$dsh" "$scratch/engine/shape/src/Host.scala" 2>"$errfile")
rm -f "$errfile"
is "a root spelled through a symlink still owns its files" "engine.shape${tab}fmt,scalafix,tests" "$link_out"
check "a symlinked parent inside the root still resolves" "$linkdir/root/engine/shape/src/Host.scala" "engine.shape${tab}fmt,scalafix,tests"

# --- a build.mill newer than the cache regenerates it from ./mill moduleMap ---------------------
seed_map
touch -t 202001010000 "$map"
touch -t 203001010000 "$scratch/build.mill"
: > "$log"

check "a newer build.mill refreshes the cache" "$scratch/engine/details/src/Wiring.scala" "engine.renamed${tab}fmt,scalafix"
# `--ticker false` is what keeps the map free of Mill's `<n>] ` line prefixes: with the ticker on
# (the default even when stdout is a pipe) every row arrives adorned. Asserted right after the one
# lookup that triggered it — build.mill stays in the future, so later lookups refresh again.
is "the refresh asked Mill for unadorned output" "mill --no-daemon --ticker false moduleMap" "$(cat "$log")"
# The refreshed map's `engine/shape` loses `tests` against the cached row, and its `scope` row is
# `fmt,tests` — the one capability combination that is not a prefix of `fmt,scalafix,tests`, so a
# validator that only knows the Layer shapes would refuse this map.
check "the refreshed map's capabilities are used too" "$scratch/engine/shape/src/Host.scala" "engine.shape${tab}fmt,scalafix"
check "a Common with tests is a capability shape of its own" "$scratch/scope/src/View.scala" "scope${tab}fmt,tests"

# --- the refreshed map is then used as-is ------------------------------------------------------
touch -t 202001010000 "$scratch/build.mill"
: > "$log"

check "the refreshed map is reused" "$scratch/engine/details/src/Wiring.scala" "engine.renamed${tab}fmt,scalafix"
is "the refreshed map is not refreshed again" "" "$(cat "$log")"

# --- a refresh that fails, or a map that is refused, is a cannot-decide -------------------------
# It must not be reported as `-`: `-` says "no module owns this", and a gate reading a refused refresh
# that way would stand down for every path in the turn.
seed_map
touch -t 202001010000 "$map"
touch -t 203001010000 "$scratch/build.mill"

cannot_decide "a failed refresh" "$scratch/engine/details/src/Wiring.scala" STUB_EXIT=1
is "a failed refresh is not moved into the cache" "engine/details${tab}engine.details${tab}fmt,scalafix,tests" "$(sed -n '3p' "$map")"
case "$(ls "$scratch/.dsh/.state")" in
  *tmp*) bad "a failed refresh leaves no temporary file behind: $(ls "$scratch/.dsh/.state")" ;;
  *) ok "a failed refresh leaves no temporary file behind" ;;
esac

# Ticker-adorned rows: the first column would carry Mill's line prefix, so no row would own anything
# and the lookup would have nothing to answer with.
cannot_decide "an adorned map" "$scratch/engine/details/src/Wiring.scala" STUB_TICKER=1
is "an adorned map does not replace the cache" "engine/details${tab}engine.details${tab}fmt,scalafix,tests" "$(sed -n '3p' "$map")"

# A capability token outside the vocabulary would tell the gate to run a check the module may not
# have, so the whole map is refused rather than half-installed.
cannot_decide "an unknown capability" "$scratch/engine/Topology.scala" STUB_BAD=1
is "an unknown capability does not replace the cache" "engine${tab}engine${tab}fmt,scalafix" "$(sed -n '1p' "$map")"

# A row whose third column is missing: reading it as "no capabilities" would silently drop the
# checks that module has, so the map is refused like any other malformed one.
cannot_decide "a row without capabilities" "$scratch/engine/shape/src/Host.scala" STUB_NO_TAB=1
is "a row without capabilities does not replace the cache" "engine/shape${tab}engine.shape${tab}fmt,scalafix,tests" "$(sed -n '2p' "$map")"

# --- no cache at all and a failing Mill: cannot decide, not "nothing owns it" -------------------
rm -f "$map"
touch -t 203001010000 "$scratch/build.mill"

cannot_decide "no cache and a failing Mill" "$scratch/engine/Topology.scala" STUB_EXIT=1
is "a failed first build leaves no cache behind" "" "$(ls "$scratch/.dsh/.state" 2>/dev/null)"

# --- and with a cache that is present and usable, an unowned path is still an answer ------------
seed_map
touch -t 202001010000 "$scratch/build.mill"
touch -t 203001010000 "$map"

check "an unowned path with a usable map answers -" "$scratch/docs/notes.md" "-"
check_status "and exits 0" "$scratch/docs/notes.md" "0"

# --- four-column maps (spec 2026-10-01 §2): field 4 lists a module's dependents with tests --------
seed_map4() {
  {
    printf 'engine\tengine\tfmt,scalafix\tengine.shape,scope\n'
    printf 'engine/shape\tengine.shape\tfmt,scalafix,tests\tscope\n'
    printf 'scope\tscope\tfmt,tests\t\n'
    printf 'bench\tbench\tfmt,scalafix,tests'
  } > "$map"
}
seed_map4
touch -t 202001010000 "$scratch/build.mill"
touch -t 203001010000 "$map"

check "a four-column row answers the lookup with id and capabilities only" "$scratch/engine/shape/src/Host.scala" "engine.shape${tab}fmt,scalafix,tests"
check "an empty fourth column keeps the capabilities intact" "$scratch/scope/src/S.scala" "scope${tab}fmt,tests"

capture_dep() { # capture_dep <id> [env…]
  cid=$1; shift
  errfile=$(mktemp)
  out=$(env "$@" GATE_ROOT="$scratch" STUB_LOG="$log" "$shell_bin" "$dsh" --dependents "$cid" 2>"$errfile")
  code=$?
  err=$(cat "$errfile"); rm -f "$errfile"
}
capture_dep engine
is "--dependents lists field 4, one per line" "$(printf 'engine.shape\nscope')" "$out"
is "--dependents exits 0" "0" "$code"
capture_dep scope
is "--dependents on an empty field 4 prints nothing" "" "$out"
is "--dependents on an empty field 4 exits 0" "0" "$code"
capture_dep bench
is "--dependents on a three-column last line without newline prints nothing" "" "$out"
capture_dep nosuch
is "--dependents on an unknown id prints nothing" "" "$out"
is "--dependents on an unknown id exits 0" "0" "$code"
capture_dep engine.sh
is "--dependents compares whole ids, never a prefix" "" "$out"

# Tab is IFS whitespace, so a `read` split merges consecutive tabs: `x<TAB>x<TAB><TAB>y` would read
# caps="y" (the dependents). The lookup must split tab-exactly — this row shape is in live maps
# (`backend/value<TAB>backend.value<TAB><TAB>app,plugin`).
mkdir -p "$scratch/x/src"
{
  printf 'x\tx\t\ty\n'
  printf 'scope\tscope\tfmt,tests\tbench,engine'
} > "$map"; touch -t 203001010000 "$map"
check "an empty-caps four-column row answers empty caps, never its dependents" "$scratch/x/src/A.scala" "x${tab}"
check_status "an empty-caps four-column row exits 0" "$scratch/x/src/A.scala" "0"
capture_dep scope
is "--dependents on a four-column last line without newline lists its ids" "$(printf 'bench\nengine')" "$out"
is "--dependents on a four-column last line without newline exits 0" "0" "$code"
check "a four-column last line without newline still owns its path" "$scratch/scope/src/S.scala" "scope${tab}fmt,tests"

printf 'engine\tengine\tfmt\tscope;rm\n' > "$map"; touch -t 203001010000 "$map"
capture_dep engine
is "--dependents on a malformed field 4 exits 3" "3" "$code"
is "--dependents on a malformed field 4 prints nothing" "" "$out"
case "$err" in *"module-map:"*) ok "--dependents on a malformed field 4 says why" ;; *) bad "--dependents on a malformed field 4 gave no reason: [$err]" ;; esac

rm -f "$map"; touch -t 203001010000 "$scratch/build.mill"
capture_dep engine STUB_EXIT=1
is "--dependents with no map and a failing Mill exits 3" "3" "$code"

# A refreshed map with four columns is installed; one with a bad field 4 is refused.
cat > "$scratch/mill4" <<'STUB'
#!/bin/sh
printf 'mill %s\n' "$*" >> "$STUB_LOG"
if [ "${STUB_BAD4:-0}" = 1 ]; then printf 'engine\tengine\tfmt\tscope;x\n'; exit 0; fi
printf 'engine\tengine\tfmt,scalafix\tscope\n'
printf 'scope\tscope\tfmt,tests\t\n'
STUB
cp "$scratch/mill" "$scratch/mill3"; cp "$scratch/mill4" "$scratch/mill"; chmod +x "$scratch/mill"
check "a refreshed four-column map is installed" "$scratch/scope/src/S.scala" "scope${tab}fmt,tests"
is "the installed map keeps field 4" "engine${tab}engine${tab}fmt,scalafix${tab}scope" "$(sed -n '1p' "$map")"
rm -f "$map"; touch -t 203001010000 "$scratch/build.mill"
cannot_decide "a refreshed map with a malformed field 4" "$scratch/scope/src/S.scala" STUB_BAD4=1
cp "$scratch/mill3" "$scratch/mill"; chmod +x "$scratch/mill"

rm -rf "$scratch" "$linkdir"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
