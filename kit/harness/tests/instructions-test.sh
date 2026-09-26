#!/bin/sh
# Direct tests for .dsh/instructions-sync.sh: the ONE sanctioned writer of .dsh/instructions/purrism.tsv.
# Run: sh .dsh/tests/instructions-test.sh
set -u
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
passed=0; failed=0
is() { if [ "$2" = "$3" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi; }
scratch=$(mktemp -d); mkdir -p "$scratch/.dsh/instructions" "$scratch/buildKit"
cp "$repo/.dsh/lib.sh" "$scratch/.dsh/lib.sh"; cp "$repo/.dsh/instructions-sync.sh" "$scratch/.dsh/instructions-sync.sh"
printf 'trait Layer {\n  def scalafixIvyDeps = Seq(\n    mvn"io.github.mercurievv:scala-purrism-scalafix_3:0.9.1",\n  )\n}\n' > "$scratch/buildKit/Layer.mill"
jar="$repo/.dsh/tests/fixtures/purrism-fake.jar"
out=$(cd "$scratch" && DSH_PURRISM_JAR="$jar" GATE_ROOT="$scratch" sh .dsh/instructions-sync.sh 2>&1); rc=$?
is "sync: writes the table from the jar" 0 "$rc"
is "sync: header from the jar" "# purrism 0.9.1" "$(head -1 "$scratch/.dsh/instructions/purrism.tsv")"
is "sync: says what it wrote" 1 "$(printf '%s\n' "$out" | grep -c 'wrote .dsh/instructions/purrism.tsv (purrism 0.9.1, 1 finding')"
sed -i.bak 's/0\.9\.1/0.9.2/' "$scratch/buildKit/Layer.mill"
out=$(cd "$scratch" && DSH_PURRISM_JAR="$jar" GATE_ROOT="$scratch" sh .dsh/instructions-sync.sh 2>&1); rc=$?
is "sync: header/version mismatch is exit 2 and names both" "2 1" "$rc $(printf '%s\n' "$out" | grep -c 'jar says 0.9.1, buildKit/Layer.mill says 0.9.2')"
is "sync: a mismatch leaves the old table in place" "# purrism 0.9.1" "$(head -1 "$scratch/.dsh/instructions/purrism.tsv")"
out=$(cd "$scratch" && DSH_PURRISM_JAR="/nonexistent.jar" GATE_ROOT="$scratch" sh .dsh/instructions-sync.sh 2>&1); rc=$?
is "sync: missing jar is exit 1" 1 "$rc"
rm -r "$scratch"
printf '%s passed, %s failed\n' "$passed" "$failed"; [ "$failed" = 0 ]
