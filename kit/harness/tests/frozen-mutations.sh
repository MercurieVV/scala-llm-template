#!/bin/sh
# The MUTATION EVIDENCE for the frozen-path rules: each rule is REMOVED on a copy of the harness, and
# the fixture that pins it must then go RED while the fixtures that do NOT pin it stay green. The rule
# behind the exercise is the one wiring-test.sh states for its own planted defects: an assertion whose
# rule can be deleted while everything stays green is not an assertion. Nothing in this checkout is
# touched -- the mutation is applied inside a scratch tree holding `.dsh/` and the cases a row names,
# and that copy's own runner decides.
#
# Each row makes three claims:
#   * the rule is spelled the way this file removes it (a no-op mutation is reported as a FAILURE,
#     never as a pass -- a mutation that changed nothing proves nothing while looking green);
#   * every case before the `--` separator passes on the unmutated copy and FAILS once the rule is
#     gone ("exactly its fixtures red");
#   * every case after the `--` (the controls: unfrozen destinations, reads, a `cd` that leaves the
#     repository, an empty list) still PASSES under the mutation -- so the rule is not load-bearing
#     for them, which is what "no over-block" means as a test.
#
# The wiring rows run `.dsh/engine/tests/wiring-test.sh`, and the installation-check rows run
# `.dsh/engine/check-harness.sh`, because neither claim is reachable from `run.sh`: the fixtures drive
# gate.sh directly, so nothing there can see a matcher that stopped selecting the tool, or prove that
# check-harness's own FAIL branch fires on a malformed entry.
#
# Why this file is NOT `*-test.sh`: check-harness.sh discovers and runs every `.dsh/engine/tests/*-test.sh`,
# and this one copies the harness once per rule and runs check-harness twice more -- evidence a human
# asks for, not a cost every installation check should pay. Run it by hand:
#
#   sh .dsh/engine/tests/frozen-mutations.sh
#
# Cost, measured on this machine: ~50 s (sixteen scratch copies of `.dsh/` and the runs under them),
# against ~16 s for the whole behavioural suite.
set -u
engine=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$engine" || exit 1
# The project's own `.dsh/` when this engine is a vendored one (`<project>/.dsh/engine`), else empty:
# the template's engine has no project state beside it. The project's own suites (the wiring suite,
# the opt-in clone suite) live in it, under proj_tests_rel.
proj_dsh=''
case "$engine" in */.dsh/engine) proj_dsh=${engine%/engine} ;; esac
proj_tests_rel=.dsh/tests

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
# skip: a row whose subject is not in this tree -- the project-owned suites under .dsh/tests exist only
# in a vendored project, so a template run names the row it cannot run instead of failing it.
skipped=0
skip() { skipped=$((skipped + 1)); printf "skip %s\n" "$1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-frozen-mutations.XXXXXX") || exit 1
trap 'rm -rf "$work"' 0
tree="$work/tree"

# build_tree <dest> <case...>: a scratch project in the vendored layout -- the project's `.dsh/`
# state when there is one, and the engine (the gate, the hooks, lib.sh, the suites and the runner)
# at `.dsh/engine/` -- plus exactly the fixture cases a row needs. The copied `.dsh/.state` is
# dropped: a per-machine cache must not decide a copied run. Run from the template (no project
# around the engine), the project state is the seed install.sh would write -- without it the tree
# had no hooks.json, cc-settings.json or frozen-paths, and the wiring and check-harness rows failed
# on every template run for want of the files they mutate.
build_tree() {
  _bt_dest=$1
  shift
  rm -rf "$_bt_dest"
  mkdir -p "$_bt_dest/.dsh"
  if [ -n "$proj_dsh" ]; then
    cp -R "$proj_dsh/." "$_bt_dest/.dsh/" 2>/dev/null
    rm -rf "$_bt_dest/.dsh/engine"
  elif [ -d "$engine/seed" ]; then
    cp -R "$engine/seed/." "$_bt_dest/.dsh/" 2>/dev/null
  fi
  mkdir -p "$_bt_dest/.dsh/engine"
  cp -R "$engine/." "$_bt_dest/.dsh/engine/" 2>/dev/null
  rm -rf "$_bt_dest/.dsh/.state" "$_bt_dest/.dsh/engine/tests/cases"
  mkdir -p "$_bt_dest/.dsh/engine/tests/cases"
  for _bt_case in "$@"; do
    cp -R "$engine/tests/cases/$_bt_case" "$_bt_dest/.dsh/engine/tests/cases/$_bt_case" || return 1
  done
  return 0
}

# mutate <file> <sed expression>: 0 when the file really changed. A mutation that did not is an
# error, not a silent pass (the same rule wiring-test.sh's `mutate` applies to its jq programs).
mutate() {
  _mu_before=$(cksum "$1" 2>/dev/null)
  sed -e "$2" "$1" > "$1.mutant" 2>/dev/null && mv "$1.mutant" "$1" || return 1
  _mu_after=$(cksum "$1" 2>/dev/null)
  [ "$_mu_before" != "$_mu_after" ]
}

case_passed() { grep -q "^ok   $2\$" "$1" 2>/dev/null; }
case_failed() { grep -q "^FAIL $2" "$1" 2>/dev/null; }

# The frozen and sealed fixtures, discovered rather than listed: a case added later is exercised by
# the base run below without an edit here. Sealed is the frozen list's own access token (a stricter
# entry, denying reads too), so its fixtures share this one base.
frozen_cases=''
frozen_n=0
for frozen_dir in "$engine"/tests/cases/frozen-*/ "$engine"/tests/cases/sealed-*/; do
  [ -d "$frozen_dir" ] || continue
  frozen_cases="$frozen_cases $(basename "$frozen_dir")"
  frozen_n=$((frozen_n + 1))
done
if [ "$frozen_n" -eq 0 ]; then
  bad "no frozen-* fixture case exists, so there is nothing to mutate against"
  printf '\n%s passed, %s failed\n' "$passed" "$failed"
  exit 1
fi

# The base: one unmutated copy with every frozen fixture in it, green. Every mutation below requires
# its cases to pass HERE first.
base="$work/base"
base_log="$work/base.log"
: >"$base_log"
if ! build_tree "$base" $frozen_cases; then
  bad "could not build the base scratch tree"
else
  sh "$base/.dsh/engine/tests/run.sh" >"$base_log" 2>&1
  base_code=$?
  if [ "$base_code" = 0 ]; then
    ok "the unmutated copy runs all $frozen_n frozen fixtures green ($(tail -n 1 "$base_log" | sed 's/^[[:space:]]*//'))"
  else
    bad "the unmutated copy is not green ($(tail -n 1 "$base_log" | sed 's/^[[:space:]]*//')), so no mutation below would prove anything"
    grep '^FAIL' "$base_log" 2>/dev/null | head -n 5 | sed 's/^/       /'
  fi
fi

# expect_mutation <name> <file in the copy> <sed> <case...> [-- <control case...>]
# The cases before `--` must go red; the ones after it must stay green.
expect_mutation() {
  _em_name=$1
  _em_file=$2
  _em_sed=$3
  shift 3
  _em_reds=''
  _em_greens=''
  _em_after=0
  for _em_case in "$@"; do
    if [ "$_em_case" = "--" ]; then _em_after=1; continue; fi
    if [ "$_em_after" = 1 ]; then _em_greens="$_em_greens $_em_case"; else _em_reds="$_em_reds $_em_case"; fi
  done
  _em_ok=1
  for _em_case in $_em_reds $_em_greens; do
    case_passed "$base_log" "$_em_case" \
      || { bad "$_em_name: $_em_case does not pass on the unmutated copy, so its verdict under the mutation would prove nothing"; _em_ok=0; }
  done
  [ "$_em_ok" = 1 ] || return 1
  if ! build_tree "$tree" $_em_reds $_em_greens; then
    bad "$_em_name: could not build the scratch tree"
    return 1
  fi
  if ! mutate "$tree/.dsh/engine/$_em_file" "$_em_sed"; then
    bad "$_em_name: the mutation changed nothing in $_em_file -- the rule is not spelled the way this script removes it, so the row proves nothing"
    return 1
  fi
  _em_log="$work/mutation-$_em_name.log"
  sh "$tree/.dsh/engine/tests/run.sh" >"$_em_log" 2>&1
  _em_red_list=''
  for _em_case in $_em_reds; do
    if case_failed "$_em_log" "$_em_case"; then
      _em_red_list="$_em_red_list $_em_case"
    else
      bad "$_em_name: $_em_case is still green with the rule removed -- the rule is not load-bearing for it"
      _em_ok=0
    fi
  done
  _em_green_n=0
  for _em_case in $_em_greens; do
    _em_green_n=$((_em_green_n + 1))
    case_passed "$_em_log" "$_em_case" \
      || { bad "$_em_name: the control $_em_case went red under the mutation -- the rule over-blocks"; _em_ok=0; }
  done
  [ "$_em_ok" = 1 ] && ok "$_em_name: $_em_red_list go red with it removed ($_em_green_n control(s) stay green)"
  return 0
}

# The wiring rows: mutate the registration, run the wiring suite in the copy, require it to fail and
# to NAME the check that the mutation breaks.
expect_wiring_mutation() { # <name> <file in the copy> <jq program> <needle> <description>
  _wm_name=$1
  _wm_file=$2
  _wm_jq=$3
  _wm_needle=$4
  _wm_what=$5
  if [ -z "$proj_dsh" ] || [ ! -f "$proj_dsh/tests/wiring-test.sh" ]; then
    skip "$_wm_name: the wiring suite is project-owned (.dsh/tests/wiring-test.sh) and absent here -- a vendored project runs this row"
    return 0
  fi
  if ! build_tree "$tree"; then
    bad "$_wm_name: could not build the scratch tree"
    return 1
  fi
  # The no-op test compares the COMPACT forms, so a mutation that only reformatted the file would be
  # caught as the no-op it is (the mutant is written back compact; the wiring suite reads JSON).
  jq -c . "$tree/$_wm_file" >"$work/wiring.before.json" 2>/dev/null
  jq -c "$_wm_jq" "$tree/$_wm_file" >"$work/wiring.after.json" 2>/dev/null
  if [ ! -s "$work/wiring.after.json" ] || cmp -s "$work/wiring.before.json" "$work/wiring.after.json"; then
    bad "$_wm_name: the mutation changed nothing in $_wm_file -- the row proves nothing"
    return 1
  fi
  cp "$work/wiring.after.json" "$tree/$_wm_file"
  _wm_log="$work/mutation-$_wm_name.log"
  sh "$tree/$proj_tests_rel/wiring-test.sh" >"$_wm_log" 2>&1
  _wm_code=$?
  if [ "$_wm_code" = 0 ]; then
    bad "$_wm_name: $_wm_what leaves the wiring suite green -- the wiring is not load-bearing"
    return 1
  fi
  if grep -q "^FAIL.*$_wm_needle" "$_wm_log" 2>/dev/null; then
    ok "$_wm_name: $_wm_what is caught by the wiring suite ($(grep -m1 '^FAIL' "$_wm_log" | cut -c1-110))"
  else
    bad "$_wm_name: the wiring suite failed, but not on the check this mutation breaks (no FAIL line names [$_wm_needle])"
  fi
  return 0
}

# The installation-check rows: check-harness's FAIL branch for a malformed frozen-path entry is
# reachable only through check-harness, and it is the thing that makes "not a silent skip" true. The
# copy's suites and fixture cases are removed so the run stops at the check under test -- its other
# FAILs (no git repository, no cases) are not what these rows assert.
harness_tree() {
  build_tree "$tree" || return 1
  rm -f "$tree"/.dsh/engine/tests/run.sh "$tree"/.dsh/engine/tests/*-test.sh "$tree/$proj_tests_rel"/*-test.sh
  mkdir -p "$tree/.dsh/.state"
  return 0
}
harness_run() { # <log>
  sh "$tree/.dsh/engine/check-harness.sh" --project "$tree" >"$1" 2>&1
}
harness_malformed='engine/details/** a single space is not a separator'

# The opt-in tree: the clone suite is KEPT (that is what the skip note is about) while `run.sh` and
# the other suites are removed, so the run stops at the discovery loop under test. The copy is not a
# git work tree, so a `--full` run REACHES the clone suite and reports it failed -- which is how the
# rows below tell "ran it" from "skipped it" without paying for a real clone.
opt_in_suite=committed-tree-test.sh
harness_tree_optin() {
  build_tree "$tree" || return 1
  rm -f "$tree/.dsh/engine/tests/run.sh" "$tree"/.dsh/engine/tests/*-test.sh
  for _ht_suite in "$tree/$proj_tests_rel"/*-test.sh; do
    [ -f "$_ht_suite" ] || continue
    case "${_ht_suite##*/}" in
      "$opt_in_suite") ;;
      *) rm -f "$_ht_suite" ;;
    esac
  done
  mkdir -p "$tree/.dsh/.state"
  return 0
}

# --- the rule table -----------------------------------------------------------------------------
# 1. the write/edit tools, before the annotated-buffer route.
expect_mutation edit-tools hooks/semantic-guard.sh \
  's/if frozen_reason=$(dsh_frozen_reason "$file_path"); then/if false; then/' \
  frozen-edit-denied frozen-edit-dir-prefix-denied frozen-edit-nonscala-denied \
  frozen-edit-spaced-path-denied \
  -- frozen-edit-nonfrozen-allowed frozen-edit-empty-list-unaffected

# 1b. the same rule restricted to `.scala`/`.sc` -- its non-Scala reach is a decision, not an accident.
expect_mutation edit-tools-scala-only hooks/semantic-guard.sh \
  's@^    file_path=$(payload_get tool_input.file_path)$@    file_path=$(payload_get tool_input.file_path); case "$file_path" in *.scala|*.sc) ;; *) file_path= ;; esac@' \
  frozen-edit-nonscala-denied -- frozen-edit-denied frozen-edit-dir-prefix-denied

# 2. a bash write, decided on its destination: every shape is a fixture of its own, and all of them
#    must go red with the one call removed.
expect_mutation bash-writes hooks/semantic-guard.sh \
  's/^  frozen_action_rows=$(dsh_bash_action_paths "$f_command")$/  frozen_action_rows=/' \
  frozen-bash-redirect-denied frozen-bash-cp-denied frozen-bash-mv-denied \
  frozen-bash-tee-denied frozen-bash-sed-i-denied frozen-bash-dd-denied \
  frozen-bash-marker-write-denied frozen-bash-quoted-redirect-nospace-denied \
  frozen-bash-quoted-redirect-denied frozen-bash-quoted-append-denied \
  frozen-bash-quoted-fd-redirect-denied frozen-bash-cp-trailing-comment-denied \
  frozen-bash-rsync-trailing-option-denied frozen-bash-install-denied \
  frozen-bash-rsync-denied frozen-bash-cp-target-dir-denied \
  frozen-bash-cp-flag-between-denied frozen-bash-cp-flag-r-between-denied \
  frozen-bash-cp-long-option-between-denied frozen-bash-rsync-flag-between-denied \
  frozen-bash-install-flag-between-denied frozen-bash-cp-leading-flag-denied \
  frozen-bash-cp-trailing-flag-denied \
  frozen-bash-cd-relative-write-denied frozen-bash-cd-subshell-write-denied \
  frozen-bash-cd-unknown-base-denied frozen-bash-cd-outside-rootspelled-denied \
  -- frozen-bash-quoted-redirect-unfrozen-ok frozen-bash-cd-outside-write-allowed \
     frozen-bash-cd-absolute-dest-allowed frozen-bash-read-allowed frozen-bash-cp-source-only-allowed

# 2e. an option BETWEEN the source and the destination: the destination is the last operand (and
#     every other operand that is not an option argument), so removing that reading hides it again.
expect_mutation bash-writes-dest-after-flag lib.sh \
  's@if (j == lastop) { emit("write", args\[j\]); continue }@@' \
  frozen-bash-cp-flag-between-denied frozen-bash-cp-flag-r-between-denied \
  frozen-bash-cp-long-option-between-denied frozen-bash-rsync-flag-between-denied \
  frozen-bash-install-flag-between-denied \
  -- frozen-bash-cp-leading-flag-denied frozen-bash-cp-trailing-flag-denied \
     frozen-bash-cp-denied frozen-bash-cp-source-only-allowed

# 2b. the extractor's command list: without install/rsync those destinations stop being seen.
expect_mutation bash-writes-install-rsync lib.sh \
  's/if (base == "cp" || base == "mv" || base == "install" || base == "rsync") {/if (base == "cp" || base == "mv") {/' \
  frozen-bash-install-denied frozen-bash-rsync-denied frozen-bash-rsync-trailing-option-denied \
  -- frozen-bash-cp-denied frozen-bash-quoted-redirect-unfrozen-ok

# 2c. the `-t`/`--target-directory` reading: the destination of `cp -t DIR src` is DIR.
expect_mutation bash-writes-target-dir lib.sh \
  's/if (base != "rsync" \&\& (a == "-t" || a == "--target-directory")) {/if (0) {/' \
  frozen-bash-cp-target-dir-denied -- frozen-bash-cp-denied

# 2d. the path/reason separator: narrowed to a single space, a spaced path is mis-read and the entry
#     silently freezes the truncated spelling instead.
expect_mutation list-separator-narrowed lib.sh \
  's/if (c == " " \&\& substr(line, i, 2) == "  ") { sep = i; break }/if (c == " ") { sep = i; break }/' \
  frozen-edit-spaced-path-denied -- frozen-edit-denied

# 3. the sanctioned MCP annotated write.
expect_mutation mcp-write hooks/semantic-guard.sh \
  's/if mcp_reason=$(dsh_frozen_reason "$mcp_path"); then/if false; then/' \
  frozen-mcp-write-denied frozen-mcp-write-dsh-server-denied frozen-mcp-write-localhost-uri-denied \
  frozen-mcp-write-encoded-uri-denied frozen-mcp-write-empty-denied \
  -- frozen-mcp-read-allowed frozen-mcp-write-outside-allowed

# 3b. the `write` argument is PRESENCE, not truthiness: with a truthiness test an empty buffer (a
#     truncation) reads as a read and is allowed.
expect_mutation mcp-write-empty-buffer lib.sh \
  's@^payload_has() {$@payload_has() { if [ -z "$(payload_get "$1")" ]; then return 1; fi@' \
  frozen-mcp-write-empty-denied -- frozen-mcp-write-denied frozen-mcp-read-allowed

# 3c. the URI spellings: without the `file://localhost` strip and the %XX decode, a URI spelling of a
#     frozen path is invisible.
expect_mutation mcp-uri-localhost hooks/semantic-guard.sh \
  '/^    file:\/\/localhost\/\*) _ml_p=/d' \
  frozen-mcp-write-localhost-uri-denied -- frozen-mcp-write-denied
expect_mutation mcp-uri-decode hooks/semantic-guard.sh \
  's@i + 2 <= n@i + 2 <= 0@' \
  frozen-mcp-write-encoded-uri-denied -- frozen-mcp-write-denied

# 4. the operand-shaped commands (tool-policy): rm/mv/ln/truncate/patch/git …/perl -i/find -delete.
# `frozen-perl-inplace-denied` and `frozen-perl-read-ok` are NOT here (spec 2026-09-28 §2): every
# `perl` invocation is now also judged by the interpreter text rule, which runs earlier in the same
# loop and denies both regardless of this operand code, so neither fixture's verdict under this
# mutation would prove anything about the operand rule any more. `frozen-perl-inplace-cd-denied` IS
# here (fix round 1, item 4, restored): its frozen spelling is split across a `cd` the interpreter
# text rule cannot see across (`cd engine && perl -i … details/A.scala` never puts `engine` and
# `details` adjacent in $cmd), so ONLY this operand code's cd-base resolution decides it -- see 4c
# below, which isolates the perl branch specifically.
expect_mutation operands hooks/tool-policy.sh \
  's/^    if \[ -n "$_fz_kind" \]; then$/    if false; then/' \
  frozen-rm-denied frozen-mv-frozen-source-denied frozen-git-checkout-denied \
  frozen-git-restore-denied frozen-git-rm-denied frozen-git-mv-denied frozen-git-apply-denied \
  frozen-patch-denied frozen-truncate-denied frozen-ln-into-frozen-dir-denied \
  frozen-find-delete-denied frozen-find-exec-rm-denied \
  frozen-rm-cd-relative-denied frozen-perl-inplace-cd-denied \
  -- frozen-git-diff-read-ok frozen-find-read-ok frozen-rm-outside-list-ok \
     frozen-rm-cd-outside-allowed frozen-ln-target-read-allowed

# 4b. the `git` arm: without it the revert reflexes stop being seen, and nothing else changes.
expect_mutation operands-git hooks/tool-policy.sh \
  's/^      git) case "$_fz_sub" in checkout|restore|rm|mv|apply) _fz_kind=operand ;; esac ;;$/      git) case "$_fz_sub" in __none__) _fz_kind=operand ;; esac ;;/' \
  frozen-git-checkout-denied frozen-git-restore-denied frozen-git-rm-denied frozen-git-mv-denied \
  frozen-git-apply-denied -- frozen-rm-denied frozen-truncate-denied frozen-git-diff-read-ok

# 4c. the writing form of perl (`-i`) is STILL load-bearing (fix round 1, item 4: the claim that it
# was fully superseded by the interpreter text rule was wrong, and this row was restored to prove
# it) -- for the ordinary case (frozen spelling literal and adjacent in $cmd) the text rule denies it
# regardless of this code, but `frozen-perl-inplace-cd-denied` uses a spelling split across a `cd`
# (`cd engine && perl -i -pe 's/a/b/' details/A.scala`) that the text rule structurally cannot see:
# `engine` and `details` are never adjacent in $cmd, only in the RESOLVED path this operand code's
# cd-base logic builds. `frozen-perl-unrelated-allowed` (a `perl` read of a path that is never frozen,
# `engine/other/B.scala`) is the control: neither the text rule nor this operand code has anything to
# say about it, mutated or not.
expect_mutation operands-perl-inplace hooks/tool-policy.sh \
  's/^      perl) for _arg in "$@"; do case "$_arg" in -i\*) _fz_kind=operand ;; esac; done ;;$/      perl) ;;/' \
  frozen-perl-inplace-cd-denied -- frozen-perl-unrelated-allowed

# 4d. the writing forms of find (`-delete`, `-exec`): its reading form stays green.
expect_mutation operands-find-forms hooks/tool-policy.sh \
  's/^      find) for _arg in "$@"; do case "$_arg" in -delete|-exec) _fz_kind=operand ;; esac; done ;;$/      find) ;;/' \
  frozen-find-delete-denied frozen-find-exec-rm-denied -- frozen-find-read-ok

# 4e. `ln` writes its LAST operand: with the scope widened to every operand, a frozen path that is
#     only the link TARGET (a read) is refused -- the over-block the control fixture catches.
expect_mutation operands-ln-scope hooks/tool-policy.sh \
  's/\[ "\$_fz_scope" = last \]/[ "$_fz_scope" = 9 ]/' \
  frozen-ln-target-read-allowed -- frozen-ln-into-frozen-dir-denied

# 4f. git's own global options before the subcommand: without the `-c`/`-C` reading, the option (or
#     its value) is mistaken for the subcommand and the write is never seen.
expect_mutation operands-git-global-options hooks/tool-policy.sh \
  's@^      -c|-C|--git-dir|--work-tree|--namespace|--exec-path|--config-env)@      --git-dir|--work-tree|--namespace|--exec-path|--config-env)@' \
  frozen-git-dashc-option-checkout-denied frozen-git-cdash-option-checkout-denied \
  -- frozen-git-checkout-denied frozen-git-diff-read-ok

# 4g. the WHOLE-TREE rule (`git checkout -- .`, `git restore .`, `git clean`, `git stash`,
#     `git reset --hard` while a frozen path exists).
expect_mutation wholesale-tree hooks/tool-policy.sh \
  's@\[ "\$_fz_whole" = 1 \]@[ "$_fz_whole" = 9 ]@' \
  frozen-git-clean-denied frozen-git-checkout-dot-denied frozen-git-restore-dot-denied \
  frozen-git-stash-denied frozen-git-stash-pop-denied frozen-git-reset-hard-denied \
  -- frozen-git-status-ok frozen-git-stash-list-ok frozen-git-clean-dry-run-ok \
     frozen-git-stash-no-freeze-ok frozen-git-checkout-dot-no-freeze-ok

# 5. the cd resolution: a relative write/operand after a literal `cd` is resolved against it, and an
#    unresolvable base is undecided rather than guessed.
expect_mutation cd-base lib.sh \
  's/^dsh_bash_cd_base() { # <rows> \[root\]$/dsh_bash_cd_base() { return 1 #/' \
  frozen-bash-cd-relative-write-denied frozen-bash-cd-subshell-write-denied \
  frozen-bash-cd-unknown-base-denied frozen-rm-cd-relative-denied \
  -- frozen-bash-cd-outside-write-allowed frozen-bash-cd-absolute-dest-allowed \
     frozen-rm-cd-outside-allowed frozen-bash-redirect-denied

# 6. the list itself: with dsh_frozen_reason answering nothing, every route goes blind at once.
expect_mutation the-list lib.sh \
  's/^dsh_frozen_reason() { /dsh_frozen_reason() { return 1; /' \
  frozen-edit-denied frozen-mcp-write-denied frozen-rm-denied frozen-bash-redirect-denied \
  -- frozen-edit-nonfrozen-allowed frozen-bash-cd-outside-write-allowed

# 7. the READ half of the MCP route: with the `write` argument no longer required, an annotated READ
#    of a frozen file is refused too -- the over-block the control fixture exists to catch.
expect_mutation mcp-read-control hooks/semantic-guard.sh \
  's/if payload_has tool_input.write \&\& \[ -n "$mcp_uri" \]; then/if [ -n "$mcp_uri" ]; then/' \
  frozen-mcp-read-allowed -- frozen-mcp-write-outside-allowed

# 7b. the seal verdict's dispatch: read/grep/glob/bash all reach deny_sealed_reads through this one
#     line, so removing it must blind every reading route to a seal at once while an unrelated read
#     and a frozen (not sealed) test read stay exactly as they were.
expect_mutation seal-read-dispatch hooks/semantic-guard.sh \
  '/^case "\$family" in read|grep|glob|bash) deny_sealed_reads ;; esac$/d' \
  sealed-read-tool-denied sealed-bash-cat-denied \
  -- frozen-test-read-allowed sealed-unrelated-read-allowed

# 8. the wiring: the MCP annotated-write group is reachable only through the registration, so its
#    removal must be caught by the wiring suite (never by a fixture, which calls gate.sh directly) --
#    in the DSH file and in the committed Claude Code template, which have to stay in step.
expect_wiring_mutation wiring-group-removed .dsh/hooks.json 'del(.PreToolUse[2])' \
  'annotated-write matcher selects' 'removing the annotated-write PreToolUse group'
expect_wiring_mutation wiring-pattern-broadened .dsh/hooks.json \
  '(.PreToolUse[] | select(.matcher | startswith("mcp__[A-Za-z0-9_-]+__")) | .matcher) = "mcp__"' \
  'matcher vocabulary is exactly' 'widening the pattern so it selects every MCP tool'
expect_wiring_mutation wiring-cc-out-of-step .dsh/cc-settings.json 'del(.hooks.PreToolUse[2])' \
  'both dialects carry the same annotated-write matcher' \
  'dropping the group from the Claude Code template only'

# 9. check-harness's frozen-path block: a malformed machine-local entry must FAIL there -- that is what
#    makes a malformed entry loud rather than a silent skip -- and the FAIL must be caused by that
#    entry and must disappear when the block is neutralised, or the check is green about nothing.
if ! harness_tree; then
  bad "check-harness-malformed-entry: could not build the scratch tree"
else
  printf '# a machine-local freeze\n%s\n' "$harness_malformed" >"$tree/.dsh/.state/frozen-paths"
  harness_run "$work/harness-malformed.log"
  h_code=$?
  if grep -q '^FAIL.*frozen-path entry.*is malformed' "$work/harness-malformed.log" 2>/dev/null; then
    ok "check-harness-malformed-entry: a malformed machine-local entry FAILs the installation check (check-harness exit $h_code)"
  else
    bad "check-harness-malformed-entry: check-harness (exit $h_code) did not FAIL on the malformed machine-local entry -- the check is green about nothing"
    grep '^FAIL' "$work/harness-malformed.log" 2>/dev/null | head -n 3 | sed 's/^/       /'
  fi
  rm -f "$tree/.dsh/.state/frozen-paths"
  harness_run "$work/harness-clean.log"
  if grep -q '^FAIL.*frozen-path entry.*is malformed' "$work/harness-clean.log" 2>/dev/null; then
    bad "check-harness-malformed-entry: the control (no machine-local entry) still FAILs on one -- the FAIL is not caused by that entry"
  else
    ok "check-harness-malformed-entry: without that entry the same copy prints no frozen-path FAIL (so the FAIL is caused by it)"
  fi
  printf '# a machine-local freeze\n%s\n' "$harness_malformed" >"$tree/.dsh/.state/frozen-paths"
  if mutate "$tree/.dsh/engine/check-harness.sh" \
     's/^  if \[ "$frozen_code" != 0 \]; then$/  if false; then/'; then
    harness_run "$work/harness-mutated.log"
    if grep -q '^FAIL.*frozen-path entry.*is malformed' "$work/harness-mutated.log" 2>/dev/null; then
      bad "check-harness-fail-branch: the FAIL survives the block being neutralised -- the row proves nothing"
    else
      ok "check-harness-fail-branch: neutralising the frozen-path block makes the malformed-entry FAIL disappear (the branch is what fails)"
    fi
  else
    bad "check-harness-fail-branch: the mutation changed nothing in check-harness.sh"
  fi
fi

# 10. the hook-file invariants (exec bit, syntax): a hook that lost its mode or cannot be parsed is
#     a committed-file defect the installation check must name -- and, as with the row above, what
#     must disappear is the FAIL, not the check.
if ! harness_tree; then
  bad "check-harness-hook-files: could not build the scratch tree"
else
  chmod -x "$tree/.dsh/engine/hooks/tool-policy.sh"
  harness_run "$work/harness-hookmode.log"
  h_code=$?
  if grep -q '^FAIL.*the gate cannot run' "$work/harness-hookmode.log" 2>/dev/null; then
    ok "check-harness-hook-files: a hook that lost its exec bit FAILs the installation check (check-harness exit $h_code)"
  else
    bad "check-harness-hook-files: check-harness (exit $h_code) did not FAIL on a non-executable hook"
    grep '^FAIL' "$work/harness-hookmode.log" 2>/dev/null | head -n 3 | sed 's/^/       /'
  fi
  chmod +x "$tree/.dsh/engine/hooks/tool-policy.sh"
  harness_run "$work/harness-hookmode-clean.log"
  if grep -q '^FAIL.*the gate cannot run' "$work/harness-hookmode-clean.log" 2>/dev/null; then
    bad "check-harness-hook-files: the control (mode restored) still FAILs on an exec bit -- the FAIL is not caused by it"
  else
    ok "check-harness-hook-files: with the mode restored the same copy prints no such FAIL (so the FAIL is caused by the bit)"
  fi
  # A syntax error is the other half: the hook would exit 1, which the bridge reads as a non-blocking
  # error, so the rule it implements would be off without a word.
  printf 'if this is not sh\n' >>"$tree/.dsh/engine/lib.sh"
  harness_run "$work/harness-hooksyntax.log"
  if grep -q '^FAIL.*the gate cannot run' "$work/harness-hooksyntax.log" 2>/dev/null; then
    ok "check-harness-hook-files: a lib.sh that does not parse FAILs the installation check (every hook sources it)"
  else
    bad "check-harness-hook-files: check-harness did not FAIL on an unparseable lib.sh"
  fi
  # The syntax mutation is undone before the exec-bit row: the two defects would otherwise both
  # print a `the gate cannot run` FAIL, and the row would prove nothing about the bit.
  cp "$engine/lib.sh" "$tree/.dsh/engine/lib.sh"
  chmod -x "$tree/.dsh/engine/hooks/tool-policy.sh"
  if mutate "$tree/.dsh/engine/check-harness.sh" \
     's/\[ -x "\$hook_file" \] || hook_bad=/[ -n "$hook_file" ] || hook_bad=/'; then
    harness_run "$work/harness-hookmode-mutated.log"
    if grep -q '^FAIL.*the gate cannot run' "$work/harness-hookmode-mutated.log" 2>/dev/null; then
      bad "check-harness-hook-files: the exec-bit FAIL survives the check being neutralised -- the row proves nothing"
    else
      ok "check-harness-hook-files: neutralising the exec-bit test makes that FAIL disappear (the check is what fails)"
    fi
  else
    bad "check-harness-hook-files: the mutation changed nothing in check-harness.sh"
  fi
fi

# 11. the `--full` flag: the clone suite is the OPT-IN half of the installation check, and its skip
#     on the default path must be a NOTE that names it -- a check that skipped the most expensive
#     suite in silence would be green about coverage it did not run. The row proves all three halves:
#     the default run skips it and says so, `--full` runs it, and a skip that printed nothing is what
#     the note assertion catches (the mutation below).
if ! harness_tree_optin; then
  bad "check-harness-full-flag: could not build the scratch tree"
else
  sh "$tree/.dsh/engine/check-harness.sh" --project "$tree" >"$work/harness-default.log" 2>&1
  if [ ! -f "$tree/$proj_tests_rel/$opt_in_suite" ]; then
    skip "check-harness-full-flag: $opt_in_suite is project-owned (.dsh/tests) and absent here, so there is no skip note to assert -- a vendored project runs this half"
  elif grep -q "^note suite $opt_in_suite: SKIPPED" "$work/harness-default.log" 2>/dev/null; then
    ok "check-harness-full-flag: the default run prints a note naming the skipped suite and the flag ($(grep -m1 "^note suite $opt_in_suite" "$work/harness-default.log" | cut -c1-90)…)"
  else
    bad "check-harness-full-flag: the default run did not print the skip note for $opt_in_suite"
  fi
  if grep -q "^ok   suite $opt_in_suite" "$work/harness-default.log" 2>/dev/null; then
    bad "check-harness-full-flag: the default run RAN $opt_in_suite -- the skip is not in effect"
  else
    ok "check-harness-full-flag: the default run does not run it"
  fi
  sh "$tree/.dsh/engine/check-harness.sh" --project "$tree" --full >"$work/harness-full.log" 2>&1
  if grep -q "^note suite $opt_in_suite: SKIPPED" "$work/harness-full.log" 2>/dev/null; then
    bad "check-harness-full-flag: --full still skips it"
  else
    ok "check-harness-full-flag: --full runs it (the copy is not a git tree, so the suite is attempted and reported failed rather than skipped)"
  fi
  sh "$tree/.dsh/engine/check-harness.sh" --project "$tree" --ful >"$work/harness-typo.log" 2>&1
  h_typo=$?
  if [ "$h_typo" = 2 ] && grep -q 'usage: sh .dsh/engine/check-harness.sh' "$work/harness-typo.log" 2>/dev/null; then
    ok "check-harness-full-flag: an unknown flag is refused with the usage line, so a typo cannot run the cheaper check by accident"
  else
    bad "check-harness-full-flag: an unknown flag was accepted (exit $h_typo) -- the default path could be run by mistake"
  fi
  if mutate "$tree/.dsh/engine/check-harness.sh" \
     's@^      note "suite \$name: SKIPPED on the default path@      : "suite $name: SKIPPED on the default path@'; then
    sh "$tree/.dsh/engine/check-harness.sh" --project "$tree" >"$work/harness-silent.log" 2>&1
    if grep -q "^note suite $opt_in_suite: SKIPPED" "$work/harness-silent.log" 2>/dev/null; then
      bad "check-harness-full-flag: the note survives the skip being made silent -- the row proves nothing"
    else
      ok "check-harness-full-flag: making the skip silent removes the note -- silence is exactly what the assertion catches"
    fi
  else
    bad "check-harness-full-flag: the mutation changed nothing in check-harness.sh"
  fi
fi

printf '\n%s passed, %s failed, %s skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ]
