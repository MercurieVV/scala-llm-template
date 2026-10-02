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
for f in contract frozen-paths hooks.json cc-settings.json policy/allowed-types.tsv policy/memorisation.tsv policy/kernels.tsv instructions/local.tsv instructions/scalac-kinds.tsv; do
  is "fresh_install_seeds: seeded $f" yes "$([ -f "$p/.dsh/$f" ] && echo yes || echo no)"
done
is "fresh_install_seeds: seeded settings enable the sandbox" true "$(dsh_json_get "$p/.dsh/cc-settings.json" sandbox.enabled)"
is "fresh_install_seeds: seeded settings name the agent output dir" '"out-agent"' "$(dsh_json_get "$p/.dsh/cc-settings.json" env.MILL_OUTPUT_DIR)"
# Ruling 29: the seed denies the whole ./out (the human's prePush compiles the holdout there) and the holdout run's
# own out-holdout, for reads and writes.
is "fresh_install_seeds: seeded denyRead" '["./out","./out-agent/holdout","./out-holdout","./holdout","./.dsh/.state/holdout.log"]' "$(dsh_json_get "$p/.dsh/cc-settings.json" sandbox.filesystem.denyRead)"
is "fresh_install_seeds: seeded denyWrite has ./out-holdout" yes "$(dsh_json_get "$p/.dsh/cc-settings.json" sandbox.filesystem.denyWrite | grep -Fq '"./out-holdout"' && echo yes || echo no)"
is "fresh_install_seeds: engine gate" yes "$([ -f "$p/.dsh/engine/gate.sh" ] && echo yes || echo no)"
is "fresh_install_seeds: no seed/ inside the engine" no "$([ -e "$p/.dsh/engine/seed" ] && echo yes || echo no)"
is "fresh_install_seeds: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"
is "fresh_install_seeds: says seeded" yes "$(printf '%s\n' "$out" | grep -q '^seeded .*contract' && echo yes || echo no)"
is "fresh_install_seeds: no ignored lines without a .gitignore" 0 "$(printf '%s\n' "$out" | grep -c '^ignored ')"

# gitignored_engine_files_are_named: an unanchored `out/` also matches the engine's fixture trees
# (.dsh/engine/tests/cases/*/root/out/...); a commit would drop those files and every clone would report the
# engine edited in place. install still succeeds (exit 0) but names each such file and the remedy.
g=$(scratch); printf 'out/\n' > "$g/.gitignore"
out=$(sh "$engine/install.sh" "$g" 2>&1); code=$?
is "gitignored_engine_files_are_named: exit" 0 "$code"
is "gitignored_engine_files_are_named: ignored lines" yes "$(printf '%s\n' "$out" | grep -Eq '^ignored  \.dsh/engine/.*/out/' && echo yes || echo no)"
is "gitignored_engine_files_are_named: one line per ignored file" \
  "$(cd "$g" && find .dsh/engine -type f | git check-ignore --stdin | wc -l | tr -d ' ')" "$(printf '%s\n' "$out" | grep -c '^ignored  ')"
is "gitignored_engine_files_are_named: remedy names the negation" yes "$(printf '%s\n' "$out" | grep -q '!/\.dsh/engine/\*\*' && echo yes || echo no)"
is "gitignored_engine_files_are_named: remedy names the pattern" yes "$(printf '%s\n' "$out" | grep -v '^ignored ' | grep -q 'out/' && echo yes || echo no)"
printf '!/.dsh/engine/**\n' >> "$g/.gitignore"
is "gitignored_engine_files_are_named: the named negation clears it" 0 "$(sh "$engine/install.sh" "$g" 2>&1 | grep -c '^ignored ')"

# committed_clone_keeps_stamp: a fresh install, committed and cloned, still verifies -- no engine file was
# lost to a .gitignore. The .gitignore is the anchored shape Setup.scala writes.
c=$(scratch); printf '/out/\n/.dsh/.state/\n/.scala-semantic/\n.bsp/\n.metals/\n.DS_Store\n' > "$c/.gitignore"
out=$(sh "$engine/install.sh" "$c" 2>&1)
is "committed_clone_keeps_stamp: no ignored lines" 0 "$(printf '%s\n' "$out" | grep -c '^ignored ')"
git -C "$c" add -A && git -C "$c" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm install
cl=$(mktemp -d); git clone -q "$c" "$cl/clone"
is "committed_clone_keeps_stamp: clone verdict" ok "$(dsh_engine_stamp_verdict "$cl/clone/.dsh/engine")"

# fresh_seeds_pass_the_installation_checks: the engine's own rule functions (the rows check-harness.sh maps)
# find nothing wrong with the seeds. The one FAIL that may remain names a file a fresh project genuinely lacks,
# with its remedy: purrism.tsv, written by `sh .dsh/engine/instructions-sync.sh` once the build declares purrism.
fails=$(cd "$p" && for fn in dsh_holdout_checks dsh_feedback_checks dsh_instruction_checks dsh_verify_checks dsh_kernel_checks; do "$fn" "$p" 2>/dev/null; done | grep '^FAIL' | grep -v 'purrism\.tsv is missing — run `sh \.dsh/engine/instructions-sync\.sh`')
is "fresh_seeds_pass_the_installation_checks: no FAIL from the seeds" "" "$fails"

# vendored_engine_is_runtime_only: the template-only files (seed/, install.sh, its test, the second-project
# smoke) never land in a project -- a vendored install-test.sh would call a vendored install.sh, which refuses
# (exit 5), and the smoke needs the template's install.sh and kit/recipes/mill.md.
for f in install.sh tests/install-test.sh tests/smoke-second-project.sh seed; do
  is "vendored_engine_is_runtime_only: no $f" no "$([ -e "$p/.dsh/engine/$f" ] && echo yes || echo no)"
done
is "vendored_engine_is_runtime_only: verdict" ok "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# template_ahead_compare_matches_fresh_vendor: group G's "moved ahead" comparison shapes the template the
# way install.sh does (both read dsh_engine_template_only), so a fresh vendor of this very tree compares
# equal. Tested on dsh_engine_template_hash, the function G calls, rather than through a full
# check-harness run, which costs ~4 minutes (it runs run.sh and every suite).
is "template_ahead_compare_matches_fresh_vendor: template hash = STAMP tree" \
  "$(dsh_engine_stamp_field "$p/.dsh/engine" tree)" "$(dsh_engine_template_hash "$engine")"

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

# vendored_install_refused: a vendored engine no longer carries install.sh (see
# vendored_engine_is_runtime_only), but a copy that somehow does is still not a template checkout; it must
# refuse before writing anything into the target. The copy is planted by hand to simulate that.
cp "$engine/install.sh" "$p/.dsh/engine/install.sh"
q=$(scratch)
sh "$p/.dsh/engine/install.sh" "$q" >/dev/null 2>&1; code=$?
is "vendored_install_refused: exit" 5 "$code"
is "vendored_install_refused: nothing written" no "$([ -e "$q/.dsh" ] && echo yes || echo no)"

# vendored_reinstall_cannot_restamp: re-running the vendored copy over its own project cannot turn an
# in-place edit back into `ok`.
printf '\n' >> "$p/.dsh/engine/lib.sh"
sh "$p/.dsh/engine/install.sh" "$p" >/dev/null 2>&1; code=$?
is "vendored_reinstall_cannot_restamp: exit" 5 "$code"
is "vendored_reinstall_cannot_restamp: verdict" mismatch "$(dsh_engine_stamp_verdict "$p/.dsh/engine")"

# vendored_detection
is "vendored_detection: vendored" 0 "$(dsh_is_vendored_engine "$p/.dsh/engine" "$p"; echo $?)"
is "vendored_detection: source tree" 1 "$(dsh_is_vendored_engine "$engine" "$p"; echo $?)"

# non_mill_detection (the positive-evidence ruling)
n=$(mktemp -d); : > "$n/build.sbt"
is "non_mill_detection: sbt" build.sbt "$(dsh_non_mill_build "$n")"
: > "$n/build.mill"; is "non_mill_detection: sbt+mill is Mill" 1 "$(dsh_non_mill_build "$n" >/dev/null; echo $?)"
e=$(mktemp -d); is "non_mill_detection: empty root is not non-Mill" 1 "$(dsh_non_mill_build "$e" >/dev/null; echo $?)"
s=$(mktemp -d); : > "$s/project.scala"; is "non_mill_detection: scala-cli" project.scala "$(dsh_non_mill_build "$s")"

# seed frozen-paths is readable and parses cleanly (the frozen grammar has no `*` globs, so
# the snapshots live under one directory frozen as `prefix/**`). Asserts the seed row shipped
# with every install.
fz_tmp=$(mktemp -d)
mkdir -p "$fz_tmp/.dsh"
cp "$engine/seed/frozen-paths" "$fz_tmp/.dsh/frozen-paths"
is "seed frozen-paths: a session's contract snapshot is frozen" \
  "the contract snapshot is the human's record of the contracts at session start" \
  "$(dsh_frozen_reason "$(dsh_repo_relpath "$(GATE_ROOT="$fz_tmp" dsh_contract_file s1)" "$fz_tmp")" "$fz_tmp")"
is "seed frozen-paths: a session's frozen-file hash record is frozen" \
  "the frozen-path hash record is the human's record of the frozen files at session start" \
  "$(dsh_frozen_reason "$(dsh_repo_relpath "$(GATE_ROOT="$fz_tmp" dsh_frozen_record_file s1)" "$fz_tmp")" "$fz_tmp")"
is "seed frozen-paths: parses with no malformed entry" "rc=0" "$(dsh_frozen_paths "$fz_tmp" >/dev/null 2>&1; printf 'rc=%s' "$?")"
rm -rf "$fz_tmp"

# vendored_engine_suites_self_contained: run the vendored copy's lib-test.sh (which has no
# project dependencies beyond dsh helpers) to guard against template-only paths leaking into
# vendored suites. A grep for template-only paths outside comments would be cheaper, but
# lib-test exercises the actual code paths the gate uses.
v_scratch=$(scratch)
sh "$engine/install.sh" "$v_scratch" >/dev/null 2>&1
v_out=$(sh "$v_scratch/.dsh/engine/tests/lib-test.sh" 2>&1); v_code=$?
is "vendored_engine_suites_self_contained: lib-test exit" 0 "$v_code"
v_failed=$(printf '%s\n' "$v_out" | grep -c '^FAIL' || true)
is "vendored_engine_suites_self_contained: lib-test no failures" 0 "$v_failed"
rm -rf "$v_scratch"

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" = 0 ]
