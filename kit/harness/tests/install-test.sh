#!/bin/sh
# install.sh and the engine stamp (spec 2026-09-26 §2): vendoring replaces the engine wholesale, seeds
# project state only where absent, and the stamp detects an engine edited in place.
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$engine/lib.sh"
passed=0; failed=0
is() { if [ "$2" = "$3" ]; then passed=$((passed+1)); printf 'ok   %s\n' "$1"; else failed=$((failed+1)); printf 'FAIL %s\n     want [%s]\n     got  [%s]\n' "$1" "$2" "$3"; fi; }
scratch() { _d=$(mktemp -d); git -C "$_d" init -q; printf '%s\n' "$_d"; }

# fresh_install_seeds: every seed lands, the engine lands with a STAMP, verdict ok.
p=$(scratch)
out=$(sh "$engine/install.sh" "$p" 2>&1); code=$?
is "fresh_install_seeds: exit" 0 "$code"
for f in contract frozen-paths hooks.json cc-settings.json policy/allowed-types.tsv policy/memorisation.tsv instructions/local.tsv instructions/scalac-kinds.tsv; do
  is "fresh_install_seeds: seeded $f" yes "$([ -f "$p/.dsh/$f" ] && echo yes || echo no)"
done
is "fresh_install_seeds: engine gate" yes "$([ -f "$p/.dsh/engine/gate.sh" ] && echo yes || echo no)"
is "fresh_install_seeds: no seed/ inside the engine" no "$([ -e "$p/.dsh/engine/seed" ] && echo yes || echo no)"
is "fresh_install_seeds: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"
is "fresh_install_seeds: says seeded" yes "$(printf '%s\n' "$out" | grep -q '^seeded .*contract' && echo yes || echo no)"

# reinstall_keeps_state: tuned state survives byte-for-byte; the engine is replaced.
printf 'roots = src\n' >> "$p/.dsh/contract"; before=$(dsh_file_hash "$p/.dsh/contract")
printf 'junk\n' > "$p/.dsh/engine/stale-file"
out=$(sh "$engine/install.sh" "$p" 2>&1)
is "reinstall_keeps_state: contract unchanged" "$before" "$(dsh_file_hash "$p/.dsh/contract")"
is "reinstall_keeps_state: says kept" yes "$(printf '%s\n' "$out" | grep -q '^kept .*contract' && echo yes || echo no)"
is "reinstall_keeps_state: stale engine file gone" no "$([ -e "$p/.dsh/engine/stale-file" ] && echo yes || echo no)"
is "reinstall_keeps_state: says replaced" yes "$(printf '%s\n' "$out" | grep -q '^replaced .*\.dsh/engine' && echo yes || echo no)"

# edited_in_place: one byte in the vendored engine flips the verdict.
printf '\n' >> "$p/.dsh/engine/lib.sh"
is "edited_in_place: verdict" mismatch "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# stamp_missing
sh "$engine/install.sh" "$p" >/dev/null 2>&1; rm "$p/.dsh/engine/STAMP"
is "stamp_missing: verdict" missing "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# ds_store_ignored
sh "$engine/install.sh" "$p" >/dev/null 2>&1; : > "$p/.dsh/engine/.DS_Store"; : > "$p/.dsh/engine/hooks/.DS_Store"
is "ds_store_ignored: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# stamp_fields: template sha is 40 hex (or `unknown`), dirty is 0|1
tpl=$(dsh_engine_stamp_field "$p/.dsh/engine" template)
is "stamp_fields: template shape" yes "$(printf '%s' "$tpl" | grep -Eq '^([0-9a-f]{40}|unknown)$' && echo yes || echo no)"
is "stamp_fields: dirty shape" yes "$(dsh_engine_stamp_field "$p/.dsh/engine" dirty | grep -Eq '^[01]$' && echo yes || echo no)"

# not_a_git_repo
d=$(mktemp -d); sh "$engine/install.sh" "$d" >/dev/null 2>&1
is "not_a_git_repo: exit" 2 "$?"
is "not_a_git_repo: nothing written" no "$([ -e "$d/.dsh" ] && echo yes || echo no)"

# usage
sh "$engine/install.sh" >/dev/null 2>&1; is "usage: exit" 1 "$?"

# failed_copy_keeps_old_engine: a copy that fails leaves the previous engine complete at the live path.
p2=$(scratch); sh "$engine/install.sh" "$p2" >/dev/null 2>&1
v_before=$(dsh_file_hash "$p2/.dsh/engine/STAMP")
DSH_INSTALL_FAIL_COPY=1 sh "$engine/install.sh" "$p2" >/dev/null 2>&1; code=$?
is "failed_copy_keeps_old_engine: exit" 4 "$code"
is "failed_copy_keeps_old_engine: STAMP unchanged" "$v_before" "$(dsh_file_hash "$p2/.dsh/engine/STAMP")"
is "failed_copy_keeps_old_engine: verdict" ok "$(dsh_engine_stamp_verdict "$p2/.dsh/engine")"
is "failed_copy_keeps_old_engine: no temp dirs left" "" "$(ls -a "$p2/.dsh" | grep '^\.engine\.' || true)"

# vendored_detection
is "vendored_detection: vendored" 0 "$(dsh_is_vendored_engine "$p/.dsh/engine" "$p"; echo $?)"
is "vendored_detection: source tree" 1 "$(dsh_is_vendored_engine "$engine" "$p"; echo $?)"

# non_mill_detection (the positive-evidence ruling)
n=$(mktemp -d); : > "$n/build.sbt"
is "non_mill_detection: sbt" build.sbt "$(dsh_non_mill_build "$n")"
: > "$n/build.mill"; is "non_mill_detection: sbt+mill is Mill" 1 "$(dsh_non_mill_build "$n" >/dev/null; echo $?)"
e=$(mktemp -d); is "non_mill_detection: empty root is not non-Mill" 1 "$(dsh_non_mill_build "$e" >/dev/null; echo $?)"
s=$(mktemp -d); : > "$s/project.scala"; is "non_mill_detection: scala-cli" project.scala "$(dsh_non_mill_build "$s")"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
