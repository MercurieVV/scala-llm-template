#!/bin/sh
# Direct tests for the feedback wrapper .dsh/engine/hooks/feedback.sh: run a command, keep the whole
# output in .dsh/.state/feedback/<utc>.log (newest 20 kept), print dsh_render_feedback's block
# (or the raw text with --raw), and exit with the command's own status.
#
# The stub transcript below mirrors the REAL weaver-scalacheck failure shape captured in
# .dsh/engine/tests/transcripts/weaver-scalacheck-fail.txt: one line ending "(...Checkers.scala:195)"
# giving the seed/try/input, then a separate "assertion failed (...)" line -- not a single
# combined line. dsh_feedback_parse joins them into one FAILURE message.
#
# Run: sh .dsh/engine/tests/feedback-test.sh
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
passed=0; failed=0
is() { if [ "$2" = "$3" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi; }
tab=$(printf '\t')
scratch=$(mktemp -d); mkdir -p "$scratch/.dsh/.state" "$scratch/app/test-draft/src/x"
mkdir -p "$scratch/.dsh/engine/hooks"; cp "$engine/lib.sh" "$scratch/.dsh/engine/lib.sh"; cp "$engine/hooks/feedback.sh" "$scratch/.dsh/engine/hooks/feedback.sh"
cat > "$scratch/stub.sh" <<'EOF'
#!/bin/sh
cat <<'T'
Running Test Class com.x.PhraseProps
com.x.PhraseProps
+ passes 1ms
- strikes are strictly increasing 4ms

*************FAILURES**************
com.x.PhraseProps
- strikes are strictly increasing 4ms
 [0] Property test failed on try 3 with seed Seed.fromBase64("AAA=") and input List(Strike(0.0), Strike(0.0)) (modules/scalacheck/src/weaver/scalacheck/Checkers.scala:195)

 [1] assertion failed (PhraseProps.scala:12)

T
exit 1
EOF
run() { (cd "$scratch" && GATE_ROOT="$scratch" sh .dsh/engine/hooks/feedback.sh "$@"); }
out=$(run -- sh stub.sh ./mill app.test); rc=$?
is "wrapper: exit status propagated" 1 "$rc"
is "wrapper: first line" "FEEDBACK: 1 passed, 1 failed (app.test)" "$(printf '%s\n' "$out" | head -1)"
is "wrapper: property line" "PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
is "wrapper: arg line" "  ARG_0: List(Strike(0.0), Strike(0.0))" "$(printf '%s\n' "$out" | sed -n 3p)"
is "wrapper: failure line joins the two real weaver lines" "  FAILURE: Property test failed on try 3: assertion failed (PhraseProps.scala:12)" "$(printf '%s\n' "$out" | sed -n 4p)"
is "wrapper: no raw leak" 0 "$(printf '%s\n' "$out" | grep -c 'Seed.fromBase64')"
log=$(ls "$scratch/.dsh/.state/feedback/"*.log | head -1)
is "wrapper: log holds the raw text" 1 "$(grep -c 'Seed.fromBase64' "$log")"
is "wrapper: summary names the log" 1 "$(printf '%s\n' "$out" | grep -c "Raw output suppressed: .* lines — .dsh/.state/feedback/")"
out=$(run --raw -- sh stub.sh ./mill app.test); is "wrapper: --raw prints everything" 1 "$(printf '%s\n' "$out" | grep -c 'Seed.fromBase64')"
# draft detection by suite file location
: > "$scratch/app/test-draft/src/x/PhraseProps.scala"
out=$(run -- sh stub.sh ./mill app.test); is "wrapper: draft suite is tagged" "DRAFT PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
rm "$scratch/app/test-draft/src/x/PhraseProps.scala"
# a fixture tree's draft (.dsh/engine/tests/cases/*/root/**) and a compiled copy under out/ are NOT the project's
# drafts: a real PhraseProps failure must stay blocking (PROPERTY:, not DRAFT PROPERTY:)
mkdir -p "$scratch/.dsh/engine/tests/cases/x/root/app/test-draft/src/x" "$scratch/out/app/test-draft/src/x"
: > "$scratch/.dsh/engine/tests/cases/x/root/app/test-draft/src/x/PhraseProps.scala"
: > "$scratch/out/app/test-draft/src/x/PhraseProps.scala"
out=$(run -- sh stub.sh ./mill app.test); is "wrapper: a fixture tree's or out/ draft does not tag the real suite" "PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
: > "$scratch/app/test-draft/src/x/PhraseProps.scala"
out=$(run -- sh stub.sh ./mill app.test); is "wrapper: the real draft still tags (fixture tree present)" "DRAFT PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
# with a coverage map, only the listed module dirs' test-draft/src count: a stray draft outside them does not
printf 'core\tcore\ttests\n' > "$scratch/.dsh/.state/modules.tsv"
out=$(run -- sh stub.sh ./mill app.test); is "wrapper: modules.tsv restricts draft roots (app not listed)" "PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
printf 'app\tapp\ttests\n' > "$scratch/.dsh/.state/modules.tsv"
out=$(run -- sh stub.sh ./mill app.test); is "wrapper: modules.tsv lists app — draft tagged" "DRAFT PROPERTY: PhraseProps.strikes are strictly increasing" "$(printf '%s\n' "$out" | sed -n 2p)"
rm -f "$scratch/.dsh/.state/modules.tsv" "$scratch/app/test-draft/src/x/PhraseProps.scala"
rm -rf "$scratch/.dsh/tests" "$scratch/out"
# stdin: the wrapped command reads nothing from the wrapper's caller
printf '#!/bin/sh\nread -r x && printf "got %%s\\n" "$x"; exit 0\n' > "$scratch/stdin.sh"
out=$(printf 'LEAK\n' | run --raw -- sh stdin.sh ./mill core.test); is "wrapper: wrapped command stdin is /dev/null" 0 "$(printf '%s\n' "$out" | grep -c 'got LEAK')"
# prune to 20
i=0; while [ $i -lt 22 ]; do run -- sh stub.sh ./mill app.test >/dev/null; i=$((i + 1)); done
is "wrapper: prunes to 20 logs" 20 "$(ls "$scratch/.dsh/.state/feedback/"*.log | wc -l | tr -d ' ')"
# green stub — ruling (spec §1): an all-green run prints exactly ONE line, no suppressed line
printf '#!/bin/sh\nprintf "com.x.A\\n+ ok 1ms\\nTotal 1, Failed 0, Passed 1, Ignored 0, Cancelled 0\\n"\n' > "$scratch/green.sh"
out=$(run -- sh green.sh ./mill core.test); rc=$?
is "wrapper: green exit 0" 0 "$rc"
is "wrapper: green run is exactly one line" 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
is "wrapper: green line" "FEEDBACK: 1 passed, 0 failed (core.test)" "$out"
# --- diagnostics through the wrapper (instruction table) ------------------------------------------
mkdir -p "$scratch/.dsh/instructions"
printf '# purrism 0.9.1\nPreferEffectIdioms.manual-resource\tPreferEffectIdioms\tT\tE\tWrap it in Resource.make\thttps://x/#effects\n' > "$scratch/.dsh/instructions/purrism.tsv"
printf '# local\n' > "$scratch/.dsh/instructions/local.tsv"
cat > "$scratch/diag-stub.sh" <<'EOF'
#!/bin/sh
cat <<'T'
[error] core.fixStrict scalafix found 2 diagnostic(s):
[WARNING][PreferEffectIdioms.manual-resource] /r/core/src/A.scala:8:5 Manual acquire/release in try/finally
[WARNING][PreferArrow.readability-budget] /r/core/src/A.scala:12:3 Arrow chain too long
T
exit 1
EOF
logout="$scratch/logpath"
out=$(DSH_FEEDBACK_LOG_OUT="$logout" run --selector core.fixStrict -- sh diag-stub.sh 2>&1); rc=$?
is "wrapper: exit status of a red fixStrict is propagated" 1 "$rc"
is "wrapper: header counts warnings" "FEEDBACK: 0 errors, 2 warnings (core.fixStrict)" "$(printf '%s\n' "$out" | sed -n 1p)"
is "wrapper: INSTRUCTION rendered from the table" 1 "$(printf '%s\n' "$out" | grep -c '^  INSTRUCTION: Wrap it in Resource.make$')"
is "wrapper: the gap is named" "No instruction for: PreferArrow.readability-budget" "$(printf '%s\n' "$out" | grep '^No instruction')"
is "wrapper: missing codes land in .dsh/.state/instructions-missing" "PreferArrow.readability-budget" "$(cat "$scratch/.dsh/.state/instructions-missing")"
is "wrapper: DSH_FEEDBACK_LOG_OUT names the raw log" 1 "$(test -f "$(cat "$logout")" && echo 1 || echo 0)"
is "wrapper: the raw log holds the raw line" 1 "$(grep -c 'scalafix found 2 diagnostic' "$(cat "$logout")")"
# the selector is inferred from a fixStrict/compile word too
out=$(run -- sh diag-stub.sh ./mill core.fixStrict 2>&1)
is "wrapper: selector inferred from a .fixStrict word" "FEEDBACK: 0 errors, 2 warnings (core.fixStrict)" "$(printf '%s\n' "$out" | sed -n 1p)"
is "wrapper: no raw diagnostic line leaks" 0 "$(printf '%s\n' "$out" | grep -c '^\[WARNING\]')"
rm -rf "$scratch"
printf '\n%s passed, %s failed\n' "$passed" "$failed"; [ "$failed" -eq 0 ]
