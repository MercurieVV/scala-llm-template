#!/bin/sh
# .dsh/engine/check-harness.sh -- is this harness actually INSTALLED, and are its guards actually capable
# of running? One line per check, exit 0 when every check passed.
#
# Why this file exists: the defect that motivated the whole .dsh/ harness was a hook config whose
# Claude Code matchers ("Bash", "Write|Edit") can never match DSH's lowercase tool names -- mounted,
# registered, and silently inert for months. A harness that is composed but not wired looks exactly
# like a harness that works, so what is asserted here is INSTALLATION, not gate logic: that the
# profile composes with the rows this repository patched into it, that the hook config names a gate
# that exists and can dispatch what it is asked for, that the semantic guard's own preconditions
# hold on this machine, and that the fixtures and suites pinning all of it are themselves intact.
#
# What it asserts, group by group:
#   A. the profile is installed and composed -- ONE `dsh --dump-config` capture, reused for every row
#   B. the gate is wired and reachable -- hooks.json parses, every command it names runs this
#      repository's gate.sh with a numeric timeout, and gate.sh dispatches each subcommand named
#   C. the semantic guard's own preconditions -- the launcher (FAIL when it is missing or not
#      executable), a SemanticDB index (a NOTE when there is none: a fresh clone has no build output,
#      and the guard stands down loudly with a reason rather than denying anything), the cached
#      session verdict (FAIL only when a file that EXISTS is unusable), and `doctor`'s CONTENT (never
#      its exit code: see the F42 note at the doctor block). The dividing line, applied to every
#      group: a build artifact or per-session cache this checkout cannot be expected to have yet is a
#      state and gets a note; a file this repository COMMITS being absent, unreadable or wrong is an
#      installation defect and gets a FAIL.
#   D. test integrity -- every fixture file is tracked by git (F27/F44), no fixture depends on a
#      directory a clone would not have (C1: emptied directories are invisible to git and to the
#      membership test above), every discovered `*-test.sh` suite passes (F49), and the behavioural
#      suite .dsh/engine/tests/run.sh -- the fixture cases that drive gate.sh end to end -- passes with them.
#      `committed-tree-test.sh` is the one suite the DEFAULT path skips (a note says so); `--full`
#      runs it
#   E. cwd binding -- this checkout is the git root process.cwd() resolves from at boot
#   F. the guidance layer -- every skill under .dsh/skills/ carries a name the provider can load
#      (I2: a name outside dsh-skill's grammar makes the provider skip the skill, silently)
#   G. the vendored engine -- a .dsh/engine/ vendored by install.sh still matches its STAMP (FAIL when
#      edited in place or the STAMP is missing); a note when run from the unvendored template tree,
#      when vendored from an uncommitted template, or when $SCALA_LLM_TEMPLATE has moved ahead
#
# What it deliberately does NOT do. The wiring suite (the project's own wiring-test.sh, beside it under <project>/.dsh/) owns the matcher
# vocabulary, the seam of every hook and the parity of the two dialects; this file only cross-checks
# that the config and gate.sh agree at all. It never runs Mill -- no check here needs a compile, and
# the index it looks for is a file on disk. It never writes inside the repository: the only writes
# are temp files under TMPDIR, which matters because bootstrap.sh runs this on every materialization.
#
# Cost and the `--full` flag, measured on this machine: the DEFAULT path is ~58 s (run.sh ~36 s for
# 232 fixtures, the five direct `*-test.sh` suites ~11 s, this file's own work -- dump, doctor,
# coverage, the fixture membership test -- ~10 s) and `--full` is ~150 s, because
# committed-tree-test.sh clones the commit and re-runs run.sh AND this whole check inside the clone.
# That suite is therefore the OPT-IN half: it is skipped by default, with a NOTE naming it, its cost
# and the flag (a green check must never imply coverage it did not run), and `--full` is the command
# that still asserts it. The class it guards -- a fixture relying on an empty directory git cannot
# store, the C1/I1 defect -- is asserted in the default path by group D's own shape checks, so the
# clone is belt-and-braces rather than the primary guard, and bootstrap.sh (which runs the default)
# pays ~58 s per materialization instead of ~150 s.
#
# `set -u`, no `set -e`: a check reports every failure it finds instead of stopping at the first.
set -u

# The flags: `--full` puts the opt-in clone suite back on the path (see group D); `--project <dir>`
# names the project whose installation is checked (default: gate_root). Anything else is refused
# loudly rather than ignored -- a typo'd `--ful` that silently ran the cheaper check would be exactly
# the "green about less than it looks" failure this file's own notes warn about.
full=0
project=''
opt_in_suite=committed-tree-test.sh
usage() {
  printf 'usage: sh .dsh/engine/check-harness.sh [--full] [--project <dir>]\n  --full           also run %s (clones this commit and runs run.sh + this check there, ~2.5 min)\n  --project <dir>  the project to check (default: gate_root)\n' "$opt_in_suite" >&2
  exit 2
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --full) full=1 ;;
    --project) [ "$#" -ge 2 ] && [ -n "$2" ] || usage; project=$2; shift ;;
    *) usage ;;
  esac
  shift
done

# The engine finds itself from its own file; the project is `--project` or gate_root.
# `cd -P`: the git root the project is compared against in E is a physical path, and `pwd` without -P
# reports a logical one -- a checkout reached through a symlink (macOS reaches /tmp through
# /private/tmp) would then fail the comparison with the harness behaving correctly. Like for like.
engine=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
# The shared coverage helpers, the same ones the health probe and the read gate use, so the fraction
# reported below is the fraction the guard acts on. Sourcing lib.sh here is safe -- it defines
# functions and one marker variable and runs nothing -- and every call below is handed the SCRATCH
# cache path, which is what keeps this check's promise never to write inside the repository.
. "$engine/lib.sh"
[ -n "$project" ] || project=$(gate_root)
repo=$(CDPATH= cd -P -- "$project" 2>/dev/null && pwd) || {
  printf 'FAIL the project directory %s does not exist\n' "$project"
  exit 1
}
cd "$repo" || exit 1
profile="${DSH_HOME:-$HOME/.dsh}/profiles/scala-arhitect"
# The installed launcher, not the repo-root `scalasemantic-mcp.sh` shim the `scala` profile names.
# health.sh resolves the same path (after its own test seam and PATH), so the two agree on what
# "the launcher is installed" means.
launcher=/Users/viktorskalinins/.local/bin/scalasemantic-mcp

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; }
# A note is neither: a STATE this checkout is allowed to be in (it has not been compiled yet, no
# session has probed in it yet), reported because the reader needs to know it, and explicitly not
# counted as coverage. Every such line names what the state is and what resolves it.
note() { printf 'note %s\n' "$1"; }
trim() { printf '%s\n' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

work=$(mktemp -d "${TMPDIR:-/tmp}/dsh-check-harness.XXXXXX") || {
  printf 'FAIL could not create a scratch directory under %s\n' "${TMPDIR:-/tmp}"
  exit 1
}
trap 'rm -rf "$work"' 0
trap 'exit 1' 1 2 3 15

printf '# harness check: %s\n' "$repo"
printf '# engine:        %s\n' "$engine"
printf '# profile:       %s\n' "$profile"

# ══ A. the profile is installed and composed ═══════════════════════════════════════════════════
# The profile directory is materialized by bootstrap.sh from .dsh/profile/ (the committed source of
# truth); a missing one means every check below would be asserting against the `scala` profile's
# defaults, which is the configuration this repository exists to stop using.
if [ -d "$profile" ]; then
  ok "profile directory is installed: $profile"
else
  bad "profile directory $profile does not exist -- run .dsh/bootstrap.sh, which materializes .dsh/profile/ into \${DSH_HOME:-\$HOME/.dsh}/profiles/scala-arhitect"
fi

dump="$work/dump"
dump_err="$work/dump.err"
dump_ok=0
if ! command -v dsh >/dev/null 2>&1; then
  bad "dsh is not on PATH -- install DSH or add it to PATH; the profile cannot be composed without it"
else
  # Captured ONCE, from the repository root (the directory a session will be launched in), and
  # reused by every row assertion below and by E.
  ( cd "$repo" && dsh --profile scala-arhitect --dump-config ) >"$dump" 2>"$dump_err"
  dump_code=$?
  if [ "$dump_code" != 0 ]; then
    dump_why=$(grep -m1 -i 'error' "$dump_err" 2>/dev/null)
    [ -n "$dump_why" ] || dump_why=$(head -n 1 "$dump_err" 2>/dev/null)
    bad "dsh --profile scala-arhitect --dump-config exited $dump_code -- the profile does not compose: $(trim "$dump_why") -- run .dsh/bootstrap.sh"
  elif [ ! -s "$dump" ]; then
    bad "dsh --profile scala-arhitect --dump-config exited 0 but printed nothing -- the profile composed to an empty tree (run .dsh/bootstrap.sh)"
  else
    dump_ok=1
    dump_rows=$(grep -c '^- ' "$dump" || true)
    ok "the profile composes: $dump_rows rows, $(wc -l <"$dump" | tr -d ' ') lines"
  fi
fi

# row <id> -- the dump lines of the row whose id is <id>, empty when there is no such row. Ids are
# what make a row patchable, so every assertion that follows is anchored to one.
row() {
  awk -v id="$1" '/^- / { inrow = ($0 == "- id: " id) } inrow { print }' "$dump"
}

row_present() { # row_present <name> <id>
  if [ "$dump_ok" != 1 ]; then
    bad "$1: the dump did not compose, so 'id: $2' could not be checked"
  elif [ -n "$(row "$2")" ]; then
    ok "$1"
  else
    bad "$1: no row with 'id: $2' in the dump -- that row is what this repository patches in; run .dsh/bootstrap.sh"
  fi
}

row_present 'mcp-scalasemantic row' mcp-scalasemantic
ms_row=$(row mcp-scalasemantic)
if [ "$dump_ok" != 1 ]; then
  bad "mcp-scalasemantic runs the installed launcher: the dump did not compose"
elif printf '%s\n' "$ms_row" | grep -Fq "command: $launcher"; then
  ok "mcp-scalasemantic runs the installed launcher ($launcher)"
else
  bad "mcp-scalasemantic does not name the installed launcher $launcher -- it must run the installed binary, never a missing repo-root scalasemantic-mcp.sh shim; edit .dsh/profile/cordis.patch.yml and re-run .dsh/bootstrap.sh"
fi

row_present 'hooks-project row' hooks-project
hook_config_path=''
hooks_row=$(row hooks-project)
if [ "$dump_ok" != 1 ]; then
  bad "hooks-project resolves the hook config from the workspace: the dump did not compose"
elif [ -z "$hooks_row" ]; then
  bad "hooks-project configPath: there is no hooks-project row, so gate.sh is never invoked (run .dsh/bootstrap.sh)"
else
  # The dump echoes `!!js` expressions UNRESOLVED, so this reads the expression itself: the bridge
  # must resolve the config from the session's cwd, and it must name THIS repository's hook config.
  hook_config_path=$(printf '%s\n' "$hooks_row" | grep -m1 'configPath:' \
    | sed -e 's/^[[:space:]]*configPath:[[:space:]]*//' -e 's/[[:space:]]*$//')
  hook_config_path=${hook_config_path%"'"}
  hook_config_path=${hook_config_path%'"'}
  if [ -z "$hook_config_path" ]; then
    bad "hooks-project has no configPath -- the bridge would have no hook config to read (run .dsh/bootstrap.sh)"
  elif [ "${hook_config_path#*process.cwd()}" = "$hook_config_path" ]; then
    bad "hooks-project configPath [$hook_config_path] is not workspace-relative (it does not mention process.cwd()) -- a fixed path would follow the launcher's directory instead of the session's"
  elif [ "${hook_config_path%/.dsh/hooks.json}" = "$hook_config_path" ]; then
    bad "hooks-project configPath [$hook_config_path] does not end in /.dsh/hooks.json -- it must name this repository's hook config"
  else
    ok "hooks-project resolves configPath from the workspace: $hook_config_path"
  fi
fi

cc_row=$(row cc-skills)
if [ "$dump_ok" != 1 ]; then
  bad "cc-skills global scanning is off: the dump did not compose"
elif printf '%s\n' "$cc_row" | grep -Fq 'enableGlobal: false'; then
  ok "cc-skills has enableGlobal: false (personal ~/.claude skills stay out)"
else
  bad "cc-skills does not have enableGlobal: false -- global ~/.claude scanning leaks unrelated personal skills into the session; set it in .dsh/profile/cordis.patch.yml"
fi

# absent <what> <fixed string> <what to do> -- the dump must NOT contain the string. Guarded on the
# compose, because "not found" in an empty dump is not evidence of absence.
absent() {
  if [ "$dump_ok" != 1 ]; then
    bad "$1 is absent: the dump did not compose, so its absence proves nothing"
  elif grep -Fq "$2" "$dump"; then
    bad "$1 is in the dump -- $3"
  else
    ok "no $1 in the dump"
  fi
}

absent 'browser MCP row' 'serverName: browser' \
  'the scala-arhitect profile deliberately drops the browser MCP row (it mounts playwright against a personal Chrome profile); remove it from .dsh/profile/cordis.patch.yml'
# Anchored to the two things a TypeScript language server cannot avoid declaring, not to the bare
# word `typescript`: over 588 dumped lines a substring that loose would false-positive the day an
# unrelated row mentions it.
absent 'TypeScript language server' 'typescript-language-server' \
  'this is a Scala repository and metals covers it; remove the server from .dsh/profile/cordis.patch.yml'
absent 'TypeScript .ts mapping' '.ts: typescript' \
  'the .ts extension mapping is what makes a server a TypeScript one; remove it from .dsh/profile/cordis.patch.yml'
absent 'repo-root scalasemantic-mcp.sh shim' 'scalasemantic-mcp.sh' \
  'that shim is not in the repository (the launcher is installed at '"$launcher"'); point the row at the installed binary'

# The census. An anonymous row (one with a name and no id) is unreachable by any later overlay: it
# cannot be patched, only replaced wholesale. The `scala` profile has three of them, which is one of
# the reasons this profile does not inherit it.
if [ "$dump_ok" != 1 ]; then
  bad "every row carries an id: the dump did not compose"
else
  rows=$(grep -c '^- ' "$dump" || true)
  ids=$(grep -c '^- id:' "$dump" || true)
  anon=$(grep -c '^- name:' "$dump" || true)
  unnamed=$(awk '/^- / && $0 !~ /^- id: / { printf "%s | ", $0 }' "$dump")
  if [ "$rows" -eq 0 ]; then
    bad "every row carries an id: the dump has no rows at all, so this check would pass vacuously"
  elif [ "$rows" -ne "$ids" ] || [ "$anon" -ne 0 ]; then
    bad "every row carries an id: $rows rows, $ids ids, $anon anonymous -- an anonymous row cannot be patched by any overlay; offenders: $unnamed"
  else
    ok "every row carries an id ($rows rows, 0 anonymous)"
  fi
fi

# F66 backstop: the patched bundle is really patched. A pristine dsh-cc-skills 0.1.2 contains ZERO
# occurrences of `eventAt` -- it reads `agent.session.events[seq]`, which is exactly the expression
# the patch replaces -- so the marker cannot appear here by accident: only the profile's own patch
# (patches/dsh-cc-skills@0.1.2.patch, applied by pnpm from pnpm-workspace.yaml) can put it there.
# Without it the rules section re-injects its message on every turn, because it can never see the
# one it already injected.
patched_bundle="$profile/node_modules/dsh-cc-skills/src/index.js"
if [ -f "$patched_bundle" ] && grep -Fq 'eventAt(seq)' "$patched_bundle"; then
  ok "the installed dsh-cc-skills carries the F66 patch marker (eventAt(seq))"
elif [ -f "$patched_bundle" ]; then
  bad "$patched_bundle is the PRISTINE bundle (no eventAt(seq)) -- the patch did not apply, so cc-skills re-injects its rules every turn; run .dsh/bootstrap.sh --force"
else
  bad "$patched_bundle does not exist -- the bundle is not installed where its patch applies; run .dsh/bootstrap.sh --force"
fi

# ══ B. the gate is wired and reachable ═════════════════════════════════════════════════════════
# The wiring suite owns the matcher vocabulary, the seam of every hook and the parity of the two
# dialects. What is cheap and worth a second, independent look is that the config parses, that every
# command in it can actually start, and that gate.sh answers to what it is asked for.
hooks_json="$repo/.dsh/hooks.json"
gate="$repo/.dsh/engine/gate.sh"

json_reader=''
if command -v jq >/dev/null 2>&1; then
  json_reader=jq
elif command -v python3 >/dev/null 2>&1; then
  json_reader=python3
fi

# hook_rows -- one line per runnable hook: <event> TAB <timeout> TAB <command>.
hook_rows() {
  if [ "$json_reader" = jq ]; then
    jq -r 'to_entries[] | .key as $e | (.value // [])[] | (.hooks // [])[]?
           | [$e, (if has("timeout") then (.timeout | tostring) else "MISSING" end), (.command // "")]
           | @tsv' "$hooks_json" 2>/dev/null
  elif [ "$json_reader" = python3 ]; then
    python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
for event, groups in d.items():
    for group in (groups or []):
        for hook in ((group or {}).get("hooks") or []):
            t = hook.get("timeout", "MISSING")
            print("%s\t%s\t%s" % (event, t, hook.get("command", "")))' "$hooks_json" 2>/dev/null
  fi
}

hook_rows_file="$work/hook-rows"
: >"$hook_rows_file"
hook_parse=1
if [ ! -f "$hooks_json" ]; then
  bad "no $hooks_json -- the hook bridge would have no config to read and NO hook would ever run (run .dsh/bootstrap.sh)"
elif [ -z "$json_reader" ]; then
  # Not a formality: lib.sh needs the same reader to judge a hook payload, so without one the whole
  # gate stands down with a reason and every hook allows everything.
  bad "no JSON reader (jq or python3) on PATH -- the hook payload cannot be parsed and the gate stands down on every call; install jq"
else
  if [ "$json_reader" = jq ]; then
    jq -e . "$hooks_json" >/dev/null 2>&1 && hook_parse=0
  else
    python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$hooks_json" >/dev/null 2>&1 && hook_parse=0
  fi
  if [ "$hook_parse" != 0 ]; then
    bad "$hooks_json is not valid JSON -- the bridge cannot read it and no hook runs; fix the syntax (see the project's wiring-test.sh)"
  else
    hook_rows >"$hook_rows_file"
    ok "$hooks_json parses ($(wc -l <"$hook_rows_file" | tr -d ' ') runnable hooks), read with $json_reader"
  fi
fi

gate_ok=0
[ -f "$gate" ] && [ -x "$gate" ] && gate_ok=1
if [ "$gate_ok" = 1 ]; then
  ok "$gate exists and is executable"
else
  bad "$gate is missing or not executable -- every command in hooks.json starts there (chmod +x .dsh/engine/gate.sh)"
fi

# Every command must resolve the gate from the session's project directory (the bridge exports
# CLAUDE_PROJECT_DIR=projectDir=process.cwd()), and must carry a timeout the bridge can use: a hook
# with no timeout is at the mercy of the bridge's default, and a non-numeric one is not a timeout.
subs="$work/subs"
: >"$subs"
bad_cmd=''
bad_timeout=''
if [ "$hook_parse" = 0 ]; then
  ifs_save=$IFS
  IFS=$(printf '\t')
  while read -r h_event h_timeout h_command; do
    case "$h_command" in
      *'${CLAUDE_PROJECT_DIR}/.dsh/engine/gate.sh'*|*'$CLAUDE_PROJECT_DIR/.dsh/engine/gate.sh'*) ;;
      *) bad_cmd="$bad_cmd $h_event->[$h_command]" ;;
    esac
    case "$h_timeout" in
      ''|*[!0-9]*) bad_timeout="$bad_timeout $h_event->[$h_timeout]" ;;
    esac
    h_sub=${h_command##* }
    h_sub=${h_sub#\"}
    h_sub=${h_sub%\"}
    [ -n "$h_sub" ] && printf '%s\n' "$h_sub" >>"$subs"
  done <"$hook_rows_file"
  IFS=$ifs_save
fi

wired=$(wc -l <"$subs" | tr -d ' ')
if [ "$hook_parse" != 0 ]; then
  bad "every hook command runs this repository's gate.sh with a numeric timeout: $hooks_json did not parse, so no command could be inspected"
elif [ "$wired" -eq 0 ]; then
  bad "hooks.json names no runnable command at all -- a config with no hook in it enforces nothing (see the project's wiring-test.sh)"
elif [ -n "$bad_cmd" ] || [ -n "$bad_timeout" ]; then
  # Both defects are named in the one line, so a config with a wrong path AND a missing timeout
  # does not hide the second one behind the first.
  why=''
  [ -n "$bad_cmd" ] && why="commands that do not resolve gate.sh from the session's project dir:$bad_cmd."
  [ -n "$bad_timeout" ] && why="$why hooks with no numeric timeout:$bad_timeout."
  bad "$why Write every hook as: sh \"\${CLAUDE_PROJECT_DIR}/.dsh/engine/gate.sh\" <subcommand> with an explicit numeric timeout"
else
  ok "every hook command resolves gate.sh from the session's project dir, with a numeric timeout ($wired hooks)"
fi

# The cheap cross-check: every subcommand the config asks for must be one gate.sh dispatches. An
# unknown subcommand exits 1 -- which the bridge treats as a NON-blocking error, i.e. silence.
if [ "$wired" = 0 ]; then
  bad "gate.sh dispatches every subcommand hooks.json names: none was named"
else
  undispatch=''
  while IFS= read -r sub; do
    grep -q "^[[:space:]]*$sub)" "$gate" 2>/dev/null || undispatch="$undispatch $sub"
  done <"$subs"
  if [ -n "$undispatch" ]; then
    bad "gate.sh does not dispatch:$undispatch -- that hook exits 1 and the bridge treats it as a non-blocking error, so the gate is silently off; add the subcommand to .dsh/engine/gate.sh"
  else
    ok "gate.sh dispatches every subcommand hooks.json names ($wired)"
  fi
fi

# Every hook FILE, and not only the subcommands: `.dsh/engine/hooks/*.sh` are committed executables, and two
# ways for one to stop being runnable are invisible everywhere else in this check. The exec bit is
# not decoration -- a bit lost in an edit (mode 100755 -> 100644, which is how this check came to
# exist) leaves a file only `sh <file>` can start, and every direct invocation of it fails. A syntax
# error is worse: the hook exits 1, which the bridge reads as a NON-blocking error, so the rule it
# implements is silently off. Both are properties of files this repository COMMITS, so both are
# FAILs, never notes -- the dividing line the rest of this file applies. `gate.sh` is held to the same
# two, and `lib.sh` (sourced by every one of them, so a syntax error there breaks all six) to the
# syntax one: it is a library, not an executable, and its mode is not a promise anyone can break.
hook_bad=''
hook_n=0
for hook_file in "$engine"/hooks/*.sh "$engine/gate.sh"; do
  [ -f "$hook_file" ] || continue
  hook_n=$((hook_n + 1))
  [ -x "$hook_file" ] || hook_bad="$hook_bad
     ${hook_file#"$engine"/}: not executable -- chmod +x it; the gate runs it through sh, but nothing else can start it"
done
for hook_file in "$engine"/hooks/*.sh "$engine/gate.sh" "$engine/lib.sh"; do
  [ -f "$hook_file" ] || continue
  if ! sh -n "$hook_file" 2>"$work/hook-syntax.err"; then
    hook_bad="$hook_bad
     ${hook_file#"$engine"/}: not sh -n clean -- $(trim "$(head -n 1 "$work/hook-syntax.err" 2>/dev/null)")"
  fi
done
if [ "$hook_n" -eq 0 ]; then
  bad "no hook file found under $engine/hooks/ -- this check would pass over an empty list, and the gate would have nothing to run"
elif [ -n "$hook_bad" ]; then
  bad "hook file(s) the gate cannot run:$hook_bad"
else
  ok "every hook file is executable and sh -n clean ($hook_n hooks + gate.sh; lib.sh sh -n clean too)"
fi

# ══ C. the semantic guard's own preconditions ══════════════════════════════════════════════════
launcher_ok=0
if [ -f "$launcher" ] && [ -x "$launcher" ]; then
  launcher_ok=1
  ok "the semantic launcher is an executable file: $launcher"
else
  bad "the semantic launcher $launcher is missing or not executable -- install scalasemantic-mcp there; the index probe reports healthy=0 without it and every Scala read and write is then allowed"
fi

# The index. Same probe as health.sh, including its prune list, because the harness's own fixtures
# are files in this checkout: .dsh holds tests/cases/health-*/root/out/.../Foo.scala.semanticdb, and
# on a fresh clone with no build output of its own those fixtures satisfied the oracle while the
# guards had nothing behind them (F46). `out` and `target` must NOT be pruned -- Mill writes the
# index inside its output dir (out/<module>/semanticDbData*.dest/classes/META-INF/semanticdb/) and
# sbt under target/scala-*/classes/, so pruning a build output is the one mistake that makes the
# probe find nothing and stand every Scala operation open.
#
# An ABSENT index is a STATE, not an installation defect, and this is the same distinction the cached
# verdict below already draws and that wiring-test draws for an absent .claude/settings.json (I1).
# `out/` is gitignored and produced by a compile this check never runs, so no fresh clone can have an
# index: failing here made `sh .dsh/engine/check-harness.sh` exit 1 in a clean `git clone` of this branch,
# and bootstrap.sh hands off to it under `set -e`, so a clean machine could not be installed at all --
# for a condition the guard already answers correctly. With no index, health reports healthy=0 and
# every Scala gate stands down LOUDLY, with a reason, instead of denying (fail-open by design, F42/F2),
# so nothing is silently enforced and nothing is broken. What the note carries is therefore guidance,
# not a verdict; what WOULD be a defect is an index that is present and inconsistent with the
# launcher's own view, and that is what the doctor cross-check below watches for.
index=$(find "$repo" \
  \( -name .dsh -o -name .superpowers -o -name .git -o -name node_modules \
     -o -name .worktrees -o -name website \) -prune -o \
  -path '*/META-INF/semanticdb/*.semanticdb' -print 2>/dev/null | head -n 1)
index_ok=0
if [ -n "$index" ]; then
  index_ok=1
  ok "a SemanticDB index exists: ${index#"$repo"/}"
else
  note "no SemanticDB index under $repo yet (looked for */META-INF/semanticdb/*.semanticdb, out/ and target/ included) — this checkout has not been compiled, which a fresh clone never is; run ./mill core.compile. Until then the semantic guard stands down instead of denying anything, and says so with a reason (health reports healthy=0), so no Scala operation is silently blocked or silently unguarded"
fi

# Coverage (F72): how much of the tree the index above actually answers for. A NOTE, never a FAIL,
# for the same reason an absent index is one. Coverage is a STATE of the checkout -- the compiler
# emits it module by module, and here `engine.details` does not compile at all while work on it is in
# flight -- and bootstrap.sh runs this check under `set -e` on every materialization, so failing on a
# partly-compiled checkout would make a clean machine uninstallable. Nothing is silently unguarded
# either: the read gate asks the per-file question, so an unindexed `.scala` read stands down with
# the file, its module and its compile command rather than being denied a tool that cannot answer it.
# The counts come from lib.sh, so this note and health.sh's `notes=` state the same fraction.
cov_cache="$work/index-coverage"
dsh_coverage_scan "$repo" "$cov_cache" >/dev/null 2>&1
cov_covered=$(dsh_coverage_count "$cov_cache")
cov_total=$(dsh_scala_source_count "$repo")
cov_unindexed=$((cov_total - cov_covered))
[ "$cov_unindexed" -ge 0 ] || cov_unindexed=0
note "$(dsh_coverage_sentence "$repo" "$cov_cache") — $cov_unindexed of $cov_total sources are unindexed, and unindexed .scala reads stand down rather than deny: the guard prints the file, its Mill module and \`./mill --ticker false --color false <module>.compile\` instead of blocking a read the semantic tools cannot answer for. That is a state and not a defect — each module that compiles extends the index for its own sources, and CAMPAIGN.md's carried gaps hold the item"

# The cached verdict. It is a per-session CACHE, not an installation artifact: the SessionStart
# health hook writes it, so a checkout no session has booted in legitimately has none, and failing
# here would make bootstrap fail on every fresh materialization. What is asserted is that whatever
# is there is readable as a verdict -- and its content is reported, because the gates read
# `^healthy=1$` and stand down silently on anything else.
verdict="$repo/.dsh/.state/health"
if [ ! -e "$verdict" ]; then
  ok "the cached health verdict is not written yet (.dsh/.state/health) -- no session has probed in this checkout; the first SessionStart writes it"
elif [ ! -r "$verdict" ]; then
  bad "$verdict exists but is unreadable -- the per-call guards read it to decide whether to enforce, and chmod +r is all it needs"
else
  v_healthy=$(sed -n 's/^healthy=//p' "$verdict" 2>/dev/null | head -n 1)
  v_reason=$(sed -n 's/^reason=//p' "$verdict" 2>/dev/null | head -n 1)
  case "$v_healthy" in
    1) ok "the cached health verdict is readable: healthy=1 reason=${v_reason:-<empty>}" ;;
    0) ok "the cached health verdict is readable: healthy=0 reason=${v_reason:-<empty>} -- the guards stand down until the next SessionStart rewrites it (this file is a per-session cache; the FAILs above are the cause to fix)" ;;
    *) bad "$verdict has no healthy= line -- the gates match ^healthy=1\$ and would stand down silently; delete the file and start a new session so the health hook rewrites it" ;;
  esac
fi

if [ "$launcher_ok" = 1 ]; then
  doc="$work/doctor"
  "$launcher" doctor --project "$repo" >"$doc" 2>&1
  dcode=$?
  # F42, measured on this machine: doctor EXITS 0 WHILE PRINTING THREE FAILS, and two of them --
  # "guard hook installed", "guard hook registered" -- describe Claude Code's own configuration
  # (.claude/hooks/, .claude/settings.json), while in DSH the semantic MCP comes from the profile's
  # cordis.patch.yml row and the guard is .dsh/engine/hooks/semantic-guard.sh. Keyed on the exit code, or
  # on those FAILs, this check would declare the harness broken in exactly the configuration where
  # it works. So: the exit code and every non-index FAIL line are reported as CONTENT and decide
  # nothing; the index line is the one signal that matters, and it is compared against the file
  # probe above rather than believed on its own.
  #
  # MEASURED, and the reason doctor's index line must NEVER be promoted to an oracle: on a copy of
  # this tree with its one real `out/…/*.semanticdb` removed, doctor printed
  #   ok    SemanticDB index — .dsh/engine/tests/cases/health-doctor-notes-truncated/root/out/mod/
  #         semanticDbData.dest/classes/META-INF/semanticdb/Foo.scala.semanticdb
  # -- a test FIXTURE -- as its index, because doctor does not prune the harness's own tree. So on a
  # fresh clone with no build output doctor says `ok` while the guards have nothing behind them: F46
  # seen from the launcher's side, and the reason the file probe above is the oracle -- it reports
  # that state as a NOTE (nothing is broken; the guard stands down loudly), and doctor's line is only
  # cross-checked against it (agreement, disagreement, or informational when the probe found none).
  # Do not "simplify" this by believing doctor, and do not read its index line as ours to fix.
  ok "doctor exited $dcode (informational -- never a criterion here)"
  doc_index_line=''
  while IFS= read -r dline || [ -n "$dline" ]; do
    dtrim=$(trim "$dline")
    [ -n "$dtrim" ] || continue
    case "$dtrim" in
      *"SemanticDB index"*) doc_index_line=$dtrim ;;
      *FAIL*) ok "doctor (informational, not a harness failure -- in DSH the MCP comes from the profile): $dtrim" ;;
      *) ok "doctor: $dtrim" ;;
    esac
  done <"$doc"
  case "$doc_index_line" in
    '') bad "doctor printed no SemanticDB index line -- the one line this check reads is gone, so its output shape changed" ;;
    *FAIL*)
      if [ "$index_ok" = 1 ]; then
        bad "doctor disagrees with the file probe above: $doc_index_line"
      else
        ok "doctor (informational -- the file probe above is the oracle, it found no index either, and that state is reported as a note rather than a failure): $doc_index_line"
      fi ;;
    *)
      if [ "$index_ok" = 1 ]; then
        ok "doctor: $doc_index_line"
      else
        ok "doctor (informational -- the file probe above is the oracle here, and doctor counts anything it finds, fixtures included): $doc_index_line"
      fi ;;
  esac
else
  bad "doctor: not run -- the launcher at $launcher is missing or not executable"
fi

# A KNOWN GAP, stated here rather than left implicit (acceptance criterion 9 / spec D-12): the Mill
# build sources (`build.mill`, `buildKit/*.mill`, `ScalafixExtra.mill`) are NOT in the semantic index
# -- measured, 0 of 118 SemanticDB files mention a build script -- so `semantic-guard` restricts
# reads of `.scala`/`.sc` only and a build file stays readable as text. That is deliberate: denying
# text tools on a file the semantic MCP cannot answer for is the deadlock the guard was built to
# avoid. Flipping it is a one-line pattern change once the build emits SemanticDB; CAMPAIGN.md
# carries the item.
note '.mill build sources are outside the semantic index (0 of 118 measured), so the guard covers .scala/.sc only (spec D-12)'

# The frozen-path list. `.dsh/frozen-paths` is COMMITTED -- a freeze is project state, reviewed
# like any other change -- so its absence is an installation defect, exactly as an absent hooks.json
# would be; the machine-local override `.dsh/.state/frozen-paths` is optional by construction.
# What is asserted is therefore: the committed file exists, and BOTH files PARSE. A malformed entry
# (no reason, an absolute path outside the repository, a relative one walking out of it, a glob that
# is not a `/**` suffix) is a FAIL here and NOWHERE ELSE: a per-call hook cannot enforce what it
# cannot parse, so it enforces the entries that did parse and stays quiet -- this check is where a
# human is told, which is what makes a malformed entry a loud installation defect rather than a
# silent skip. The entries are then listed by name: "3 paths are frozen" is not something a human
# can review, and a freeze is a decision they are meant to see.
frozen_committed="$repo/.dsh/frozen-paths"
if [ ! -f "$frozen_committed" ]; then
  bad "$frozen_committed is missing -- that committed list is what every hook reads to keep an agent out of the human's in-flight work; restore it (an EMPTY file is the legitimate 'nothing is frozen' state, a missing one is not)"
else
  frozen_out="$work/frozen-paths.out"
  frozen_err="$work/frozen-paths.err"
  dsh_frozen_paths "$repo" >"$frozen_out" 2>"$frozen_err"
  frozen_code=$?
  frozen_n=$(wc -l <"$frozen_out" | tr -d ' ')
  if [ "$frozen_code" != 0 ]; then
    frozen_bad=$(bound_lines "$(cat "$frozen_err" 2>/dev/null)" 10 | sed 's/^/       /')
    bad "a frozen-path entry in $frozen_committed or $repo/.dsh/.state/frozen-paths is malformed -- the hooks enforce only the entries that parse, so the malformed one protects nothing, silently:
$frozen_bad
     fix: one entry per line, '<path | dir/ | prefix/**>' then whitespace then a reason"
  elif [ "$frozen_n" = 0 ]; then
    ok "the frozen-path list parses and nothing is frozen right now ($frozen_committed is empty of entries)"
  else
    frozen_names=''
    while IFS= read -r frozen_row; do
      [ -n "$frozen_row" ] || continue
      frozen_names="$frozen_names
     $(printf '%s' "$frozen_row" | cut -f1,2,3 | tr '\t' ' ')"
    done <"$frozen_out"
    ok "the frozen-path list parses: $frozen_n frozen path(s), from $frozen_committed and $repo/.dsh/.state/frozen-paths — every write route denies them, and a sealed entry denies reads too:$frozen_names"
  fi
fi

# The test-protection and holdout rules (spec 2026-09-19-test-protection-and-holdout-design §3):
# one lib.sh function, so the rules are unit-tested in lib-test.sh and mapped here onto ok/FAIL/note.
tab=$(printf '\t')
hc_rows=$(dsh_holdout_checks "$repo" 2>&1) || :
while IFS="$tab" read -r hc_kind hc_msg; do
  [ -n "$hc_kind" ] || continue
  case "$hc_kind" in
    ok) ok "$hc_msg" ;;
    FAIL) bad "$hc_msg" ;;
    note) note "$hc_msg" ;;
    *) bad "dsh_holdout_checks printed a row this check does not understand: $hc_kind $hc_msg" ;;
  esac
done <<EOF
$hc_rows
EOF

# The structural holdout seal (spec 2026-10-02 §4.4): the agent's sandbox settings, same row shape as above.
sb_rows=$(dsh_sandbox_checks "$repo" 2>&1) || :
while IFS="$tab" read -r sb_kind sb_msg; do
  [ -n "$sb_kind" ] || continue
  case "$sb_kind" in
    ok) ok "$sb_msg" ;;
    FAIL) bad "$sb_msg" ;;
    note) note "$sb_msg" ;;
    *) bad "dsh_sandbox_checks printed a row this check does not understand: $sb_kind $sb_msg" ;;
  esac
done <<EOF
$sb_rows
EOF

# The module map's dependents column (spec 2026-10-01 §4): same row shape as the holdout rows above.
dc_rows=$(dsh_dependents_column_check "$repo" 2>&1) || :
while IFS="$tab" read -r dc_kind dc_msg; do
  [ -n "$dc_kind" ] || continue
  case "$dc_kind" in
    ok) ok "$dc_msg" ;;
    note) note "$dc_msg" ;;
    *) bad "dsh_dependents_column_check printed a row this check does not understand: $dc_kind $dc_msg" ;;
  esac
done <<EOF
$dc_rows
EOF

# The property-feedback installation rules (spec 2026-09-20-property-feedback-loop-design §3): same
# shape as the holdout rows above -- one lib.sh function, unit-tested in lib-test.sh, mapped here.
fc_rows=$(dsh_feedback_checks "$repo" "$engine" 2>&1) || :
while IFS="$tab" read -r fc_kind fc_msg; do
  [ -n "$fc_kind" ] || continue
  case "$fc_kind" in
    ok) ok "$fc_msg" ;;
    FAIL) bad "$fc_msg" ;;
    note) note "$fc_msg" ;;
    *) bad "dsh_feedback_checks printed a row this check does not understand: $fc_kind $fc_msg" ;;
  esac
done <<EOF
$fc_rows
EOF

# The instruction-table installation rules (spec 2026-09-20 diagnostic→instruction §3): same shape
# again -- one lib.sh function, unit-tested in lib-test.sh, mapped here.
ic_rows=$(dsh_instruction_checks "$repo" 2>&1) || :
while IFS="$tab" read -r ic_kind ic_msg; do
  [ -n "$ic_kind" ] || continue
  case "$ic_kind" in
    ok) ok "$ic_msg" ;;
    FAIL) bad "$ic_msg" ;;
    note) note "$ic_msg" ;;
    *) bad "dsh_instruction_checks printed a row this check does not understand: $ic_kind $ic_msg" ;;
  esac
done <<EOF
$ic_rows
EOF

# The diff-scoped verification installation rules (spec 2026-09-24 §3): same shape again -- one
# lib.sh function, unit-tested in lib-test.sh, mapped here.
vk_rows=$(dsh_verify_checks "$repo" "$engine" 2>&1) || :
while IFS="$tab" read -r vk_kind vk_msg; do
  [ -n "$vk_kind" ] || continue
  case "$vk_kind" in
    ok) ok "$vk_msg" ;;
    FAIL) bad "$vk_msg" ;;
    note) note "$vk_msg" ;;
    *) bad "dsh_verify_checks printed a row this check does not understand: $vk_kind $vk_msg" ;;
  esac
done <<EOF
$vk_rows
EOF

# The kernel registry installation rules (spec 2026-09-27 §1–2): same shape again -- one lib.sh
# function, unit-tested in lib-test.sh, mapped here.
kk_rows=$(dsh_kernel_checks "$repo" 2>&1) || :
while IFS="$tab" read -r kk_kind kk_msg; do
  [ -n "$kk_kind" ] || continue
  case "$kk_kind" in
    ok) ok "$kk_msg" ;;
    FAIL) bad "$kk_msg" ;;
    note) note "$kk_msg" ;;
    *) bad "dsh_kernel_checks printed a row this check does not understand: $kk_kind $kk_msg" ;;
  esac
done <<EOF
$kk_rows
EOF

# The Stop hook's mode table (spec 2026-10-10): same shape, one lib.sh function.
tm_rows=$(dsh_turn_end_mode_checks "$repo" 2>&1) || :
while IFS="$tab" read -r tm_kind tm_msg; do
  [ -n "$tm_kind" ] || continue
  case "$tm_kind" in
    ok) ok "$tm_msg" ;;
    FAIL) bad "$tm_msg" ;;
    note) note "$tm_msg" ;;
    *) bad "dsh_turn_end_mode_checks printed a row this check does not understand: $tm_kind $tm_msg" ;;
  esac
done <<EOF
$tm_rows
EOF

# The git-ignored frozen-file record (spec 2026-09-28 §1 item 2): same shape again -- one lib.sh
# function, unit-tested in lib-test.sh, mapped here.
fr_rows=$(dsh_frozen_record_checks "$repo" 2>&1) || :
while IFS="$tab" read -r fr_kind fr_msg; do
  [ -n "$fr_kind" ] || continue
  case "$fr_kind" in
    ok) ok "$fr_msg" ;;
    FAIL) bad "$fr_msg" ;;
    note) note "$fr_msg" ;;
    *) bad "dsh_frozen_record_checks printed a row this check does not understand: $fr_kind $fr_msg" ;;
  esac
done <<EOF
$fr_rows
EOF

# ══ D. the repository's test integrity ═════════════════════════════════════════════════════════
# F27/F44. The fixtures under .dsh/engine/tests/cases/*/root/ are inputs to the gate, and they have been
# silently dropped from commits three separate times by ignore patterns that match a directory name
# at ANY depth (`.claude/` on .gitignore:116, `out/` on :52). The negations added each time cover
# only the paths known then, so this is a membership test against git rather than a pattern test: a
# NEW fixture file under ANY root/ tree fails here, in the checkout that has it, instead of vanishing
# from someone else's clone and turning a case into a vacuous pass.
fixture_list="$work/fixtures"
: >"$fixture_list"
# Newline-delimited: paths with spaces survive, and fixture names never contain a newline.
find "$engine/tests/cases" -path '*/root/*' \( -type f -o -type l \) -print 2>/dev/null | sort >"$fixture_list"
fixture_count=$(wc -l <"$fixture_list" | tr -d ' ')
if [ "$fixture_count" -eq 0 ]; then
  bad "no fixture files at all under .dsh/engine/tests/cases/*/root/ -- this check would pass vacuously; the fixture trees are missing from this checkout"
elif ! git -C "$engine" rev-parse --git-dir >/dev/null 2>&1; then
  bad "$engine is not in a git repository (git rev-parse --git-dir failed) -- nothing here can be verified as tracked, and an untracked fixture is exactly the defect this check exists for; run the check inside a checkout"
else
  untracked=''
  n_untracked=0
  while IFS= read -r fixture; do
    rel=${fixture#"$engine"/}
    if ! git -C "$engine" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1; then
      n_untracked=$((n_untracked + 1))
      why=$(git -C "$engine" check-ignore -v -- "$rel" 2>/dev/null)
      if [ -n "$why" ]; then
        untracked="$untracked
     $rel
       ignored by: $(trim "$why")"
      else
        untracked="$untracked
     $rel
       not in the index at all"
      fi
    fi
  done <"$fixture_list"
  if [ "$n_untracked" -eq 0 ]; then
    ok "every fixture file under .dsh/engine/tests/cases/*/root/ is tracked by git ($fixture_count files)"
  else
    bad "$n_untracked of $fixture_count fixture files under .dsh/engine/tests/cases/*/root/ are NOT tracked by git -- they vanish from a fresh clone and the case they belong to stops testing anything; git add -f them, or rename them out of the ignored path:$untracked"
  fi
fi

# C1. The membership test above cannot see a directory that holds no file, and git stores no such
# thing: an EMPTY fixture directory is present in the checkout that wrote it and simply absent in a
# clone. Three turn-end cases shipped one (`root/engine/shape/test/src`, the redirect target of each
# case's post_git), and the committed tree therefore could not reproduce its own evidence --
# measured, `sh .dsh/engine/tests/run.sh` in a `git clone --depth 1` of this branch was **108 passed, 3
# failed** ("post_git could not turn the base repository dirty") against 111/0 in the checkout that
# had the directories, which also made `bootstrap.sh` (which hands off to this file under `set -e`)
# fail on a clean machine. Two SHAPE assertions for that class, because membership cannot express
# either:
#   * no directory under a case's root/ tree is empty -- git cannot commit one, so a clone will not
#     have it and nothing may depend on it. A case that needs a directory builds it in its own
#     post_git (`mkdir -p`), which is what those three cases now do;
#   * every directory a case's post_git/mutate_between redirects INTO is materialised in a clone:
#     the script makes it, the runner makes it (`.` the scratch root, `.git` from git_init,
#     `.dsh/.state` from run.sh), or git does, because the case's root/ tree holds at least one
#     TRACKED file under it. A destination that is none of those is exactly C1 again.
empty_fixture_dirs=$(find "$engine/tests/cases" -path '*/root/*' -type d -empty -print 2>/dev/null | sort)
if [ -z "$empty_fixture_dirs" ]; then
  ok "no empty directory under any .dsh/engine/tests/cases/*/root/ tree (git cannot store one, so a clone would not have it)"
else
  bad "empty director(ies) under a fixture root/ tree -- git stores no empty directory, so each is present here and GONE in a fresh clone, where every case that writes into it fails:
$(printf '%s\n' "$empty_fixture_dirs" | sed 's/^/       /')
     fix: have the case create it (mkdir -p in its post_git) instead of shipping it"
fi

# The same class, one step further in: a directory that exists here only because something else in
# this checkout made it. What the case itself declares is what counts, so this is a static reading of
# the two scripts the runner executes against the copied tree (run.sh's `post_git` and
# `mutate_between`) rather than a second run of them. The reading lives in lib.sh
# (`dsh_fixture_shape_gaps`) so the template's own lib-test asserts it too.
shape_out=$(dsh_fixture_shape_gaps "$engine")
shape_count=$(printf '%s\n' "$shape_out" | sed -n '1s/^count //p')
shape_writers=${shape_count% *}
shape_dirs=${shape_count#* }
shape_bad=$(printf '%s\n' "$shape_out" | sed '1d' | sed 's/^/     /')
[ -n "$shape_bad" ] && shape_bad="
$shape_bad"
if [ -n "$shape_bad" ]; then
  bad "the fixture writers depend on directories a clone would not have:$shape_bad"
elif [ "$shape_dirs" -eq 0 ]; then
  bad "no redirect destination found in any post_git/mutate_between ($shape_writers scripts read) -- the extraction above found nothing to assert, which is not the same as everything being in order"
else
  ok "every directory a fixture post_git/mutate_between writes into survives a clone ($shape_writers scripts, $shape_dirs destinations: created by the script, by the runner, or by tracked files under root/)"
fi

# F49. Every suite discovers itself: hard-coding the list was how a seventh suite would be
# forgotten. A non-executable suite still runs here (it is invoked through `sh`, like every other
# suite and like gate.sh invokes its hooks), but it is still an installation defect worth naming:
# `.dsh/engine/tests/<suite>` fails to start. The empty list is the loud case -- a discovery loop over
# nothing must not read as "all suites passed".
#
# THE ONE OPT-IN SUITE (the `--full` flag). `committed-tree-test.sh` clones this commit and runs
# `run.sh` AND this whole check inside that clone, so it roughly doubles the cost of every
# materialization: measured on this machine, 186 s with it on the default path against ~40 s without.
# What it exists for is the C1 class (a fixture depending on an empty directory git cannot store),
# and group D's own shape assertions in the DEFAULT path already catch that class cheaply -- so the
# clone test is belt-and-braces rather than the primary guard, and paying minutes per bootstrap is
# not a price the default path should carry. It is therefore SKIPPED unless `--full` is given, and
# the skip is a NOTE naming the suite, what it costs and the flag that runs it: never silence,
# because a green check must not imply coverage it did not run. `.dsh/bootstrap.sh` keeps using the
# default; `sh .dsh/engine/check-harness.sh --full` is the command that still asserts the clone.
suites="$work/suites"
: >"$suites"
# The engine's own suites first, then the project's (`<project>/.dsh/tests`, where the suites that
# read the project's own wiring live -- the opt-in clone suite among them), when that directory exists.
for suite in "$engine"/tests/*-test.sh; do
  [ -f "$suite" ] || continue
  printf '%s\n' "$suite" >>"$suites"
done
project_tests="$repo/.dsh/tests"
if [ -d "$project_tests" ]; then
  for suite in "$project_tests"/*-test.sh; do
    [ -f "$suite" ] || continue
    printf '%s\n' "$suite" >>"$suites"
  done
fi
suite_count=$(wc -l <"$suites" | tr -d ' ')

if [ "$suite_count" -eq 0 ]; then
  bad "no .dsh/engine/tests/*-test.sh suites were found -- the discovery branch would pass over an empty list; the suites are missing from this checkout"
else
  not_exec=''
  while IFS= read -r suite; do
    [ -x "$suite" ] || not_exec="$not_exec ${suite##*/}"
  done <"$suites"
  if [ -n "$not_exec" ]; then
    bad "suite(s) not executable:$not_exec -- chmod +x them; this check and gate.sh run them through sh, but ./.dsh/engine/tests/<suite> would not start"
  else
    ok "every discovered suite is executable ($suite_count suites)"
  fi

  while IFS= read -r suite; do
    name=${suite##*/}
    if [ "$full" != 1 ] && [ "$suite" = "$project_tests/$opt_in_suite" ]; then
      note "suite $name: SKIPPED on the default path (it clones this commit and runs run.sh plus this whole check inside the clone, ~2.5 min). The C1 class it guards -- a fixture relying on an empty directory git cannot store -- is asserted here by group D's shape checks; 'sh .dsh/engine/check-harness.sh --full' runs it"
      continue
    fi
    log="$work/suite-$name.log"
    sh "$suite" >"$log" 2>&1
    code=$?
    summary=$(trim "$(tail -n 1 "$log" 2>/dev/null)")
    if [ "$code" = 0 ]; then
      ok "suite $name: $summary"
    else
      bad "suite $name failed (exit $code): $summary -- run sh $suite for the full output"
      grep '^FAIL' "$log" 2>/dev/null | head -n 5 | sed 's/^/       /'
    fi
  done <"$suites"
fi

# The behavioural suite. F49's discovery pattern is `*-test.sh`, which leaves `.dsh/engine/tests/run.sh`
# out -- and run.sh is the fixture runner: 111 cases today that drive gate.sh and every hook end to
# end through payloads, exit codes and git state. It is the largest single piece of evidence that
# the installation under test actually works, so an installation check that skips it is weaker than
# it looks. Invoked exactly like the discovered suites, through `sh <file>`, so the interpreter
# question stays the runner's (it names the interpreter it is running under in its own first line).
# Measured cost on this machine: ~16 s, which puts a whole check at ~23 s -- paid once per
# materialization by bootstrap, and worth it. If that ever becomes unacceptable, put this block
# behind a `--full` flag AND print a skip line, so a green check never implies coverage it skipped.
behaviour="$engine/tests/run.sh"
if [ ! -f "$behaviour" ]; then
  bad ".dsh/engine/tests/run.sh is missing -- the fixture cases that drive the gate end to end are gone with it; restore the file (every case under .dsh/engine/tests/cases is only as good as the runner that plays it)"
else
  if [ -x "$behaviour" ]; then
    ok "the behavioural suite .dsh/engine/tests/run.sh is executable"
  else
    bad ".dsh/engine/tests/run.sh is not executable -- chmod +x .dsh/engine/tests/run.sh; this check runs it through sh, but ./.dsh/engine/tests/run.sh would not start"
  fi
  behaviour_log="$work/suite-run.log"
  sh "$behaviour" >"$behaviour_log" 2>&1
  behaviour_code=$?
  behaviour_summary=$(trim "$(tail -n 1 "$behaviour_log" 2>/dev/null)")
  if [ "$behaviour_code" = 0 ]; then
    ok "behavioural suite .dsh/engine/tests/run.sh: $behaviour_summary"
  else
    bad "behavioural suite .dsh/engine/tests/run.sh failed (exit $behaviour_code): $behaviour_summary -- run sh .dsh/engine/tests/run.sh for the full output"
    grep '^FAIL' "$behaviour_log" 2>/dev/null | head -n 5 | sed 's/^/       /'
  fi
fi

# ══ E. cwd binding ═════════════════════════════════════════════════════════════════════════════
# The profile resolves the hook config from process.cwd(), so a session booted outside this
# repository finds no .dsh/hooks.json and no hook ever runs -- a harness that is installed, composed
# and inert, which is the defect this whole check exists for. TWO things are asserted: that the
# directory this file computes as its root IS the git root (so process.cwd() + '/.dsh/hooks.json'
# lands on the config B just checked), and that `.dsh/dsh.sh` is the launcher that GUARANTEES that
# binding -- it must exist, be executable, and `cd` to the repository root before it execs `dsh`.
#
# The launcher assertion is the one acceptance criterion 7 asks for and this file used to only
# document (M10): documenting a guard is not checking it, and a launcher whose `cd` was dropped (or
# whose executable bit was lost) would leave every session's cwd at the caller's directory, where
# `process.cwd()` resolves the profile's configPath to nothing and every hook stands down in silence.
# The `cd` is read off the launcher's own source: the line has to be a `cd` that names the repository
# root, spelled through the launcher's own `$repo`/`$0` computation, not a literal path (a checkout
# is not always where it was when this was written).
launcher_sh="$repo/.dsh/dsh.sh"
if [ ! -f "$launcher_sh" ]; then
  bad "cwd binding: .dsh/dsh.sh is missing -- it is the launcher that cds to the repository root, so without it a session's process.cwd() is wherever the user happened to be and the profile resolves no hook config (acceptance criterion 7)"
elif [ ! -x "$launcher_sh" ]; then
  bad "cwd binding: .dsh/dsh.sh is not executable -- chmod +x .dsh/dsh.sh; the cd it performs is what makes process.cwd() resolve this repository's configPath, and a non-executable launcher is never run"
else
  launcher_cd=$(sed -n 's/^[[:space:]]*\(cd[[:space:]][^#]*\).*/\1/p' "$launcher_sh" | head -n 1 | sed 's/[[:space:]]*$//')
  case "$launcher_cd" in
    '') bad "cwd binding: .dsh/dsh.sh contains no \`cd\` line -- that line is the guard: without it the launcher execs dsh from the caller's directory and process.cwd()-relative configPath resolves elsewhere (acceptance criterion 7)" ;;
    'cd "$repo"'|'cd "$repo" '*) ok "cwd binding: .dsh/dsh.sh is executable and cds to the repository root before execing dsh ($launcher_cd)" ;;
    *) bad "cwd binding: .dsh/dsh.sh's cd line is [$launcher_cd], which does not cd to the repository root it resolved -- the guard only works if it enters the root before \`exec dsh\`" ;;
  esac
fi

toplevel=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)
if [ "$toplevel" = "$repo" ]; then
  ok "cwd binding: $repo is the git worktree root -- a session launched by .dsh/dsh.sh boots with process.cwd() here"
else
  bad "cwd binding: this check runs from $repo, which is not the git root (${toplevel:-git could not name one}) -- process.cwd() at boot would resolve the hook config somewhere else; launch sessions with .dsh/dsh.sh"
fi

if [ -z "$hook_config_path" ]; then
  bad "cwd binding: the profile's configPath could not be read from the dump, so it cannot be resolved against this root"
else
  # The expression is `!!js process.cwd() + '<suffix>'`: take what is added to the cwd and resolve it
  # here, which is the same computation the profile performs at boot.
  cp_suffix=$(printf '%s' "${hook_config_path#*process.cwd()}" | sed -e 's/^[[:space:]]*+[[:space:]]*//' -e "s/^['\"]//" -e "s/['\"]$//")
  case "$cp_suffix" in
    /*) if [ -f "$repo$cp_suffix" ]; then
          ok "cwd binding: process.cwd() + '$cp_suffix' resolves to the hook config B checked ($repo$cp_suffix)"
        else
          bad "cwd binding: process.cwd() + '$cp_suffix' resolves to $repo$cp_suffix, which does not exist -- a session booted at the root would find no hook config and no hook would run (run .dsh/bootstrap.sh)"
        fi ;;
    *) bad "cwd binding: the configPath suffix [$cp_suffix] is not an absolute path off the cwd -- it cannot be resolved against $repo" ;;
  esac
fi

# ══ F. the guidance layer: every projected skill can actually load ══════════════════════════════
# I2. `.dsh/skills/` is projected into the agent's skill catalog, and the provider that reads it
# VALIDATES the front-matter `name:` against dsh-skill's grammar `/^[a-z0-9]+(?:-[a-z0-9]+)*$/`: a
# name outside it is warned about and that skill is SKIPPED, silently as far as the session is
# concerned. Measured before this check existed, `Shaping-A-Module`, `Verify-Before-Done` and
# `Reshaping-Module-By-Linters` were all rejected, so three of this repository's six skills could
# never load — the founding defect (a guard that is registered, mounted and inert) reproduced inside
# the guidance layer built to prevent it. The rule is read off the file the provider reads, so a
# seventh skill cannot arrive silently inert: one regex over `name:`, a non-empty `description:`, and
# the repository's own convention that the name is the directory's.
skills_checked=0
skills_bad=''
for skill_file in "$repo"/.dsh/skills/*/SKILL.md; do
  [ -f "$skill_file" ] || continue
  skills_checked=$((skills_checked + 1))
  skill_dir=${skill_file%/*}
  skill_id=${skill_dir##*/}
  # The front matter only (the block the provider parses), never a `name:`/`description:` further
  # down the prose, and the value with one layer of quotes and trailing space removed.
  skill_front=$(sed -n '1,8p' "$skill_file" 2>/dev/null)
  skill_name=$(printf '%s\n' "$skill_front" | sed -n 's/^name:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/^["'"'"']//' -e 's/["'"'"']$//' -e 's/[[:space:]]*$//')
  skill_desc=$(printf '%s\n' "$skill_front" | sed -n 's/^description:[[:space:]]*//p' | head -n 1 \
    | sed -e 's/[[:space:]]*$//')
  if [ -z "$skill_name" ]; then
    skills_bad="$skills_bad
     $skill_id: no \`name:\` in the first 8 lines — the provider cannot read a name, so the skill is skipped"
  elif ! printf '%s' "$skill_name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    skills_bad="$skills_bad
     $skill_id: name: $skill_name — outside dsh-skill's grammar ^[a-z0-9]+(-[a-z0-9]+)*\$, which is validated when the skill is read and makes the skill SKIPPED with a warning nobody sees"
  elif [ "$skill_name" != "$skill_id" ]; then
    skills_bad="$skills_bad
     $skill_id: name: $skill_name differs from its directory name — this repository's skills are named for their directory (the id a session sees), and a mismatch is how the three CamelCase names above stayed invisible"
  fi
  if [ -z "$skill_desc" ]; then
    skills_bad="$skills_bad
     $skill_id: no non-empty \`description:\` in the first 8 lines — a skill an agent is never told about is a skill that never runs"
  fi
done
if [ "$skills_checked" -eq 0 ]; then
  bad "no SKILL.md found under $repo/.dsh/skills/*/ — this check would pass over an empty list, and the guidance layer is missing from this checkout"
elif [ -n "$skills_bad" ]; then
  bad "skill front matter that cannot load:$skills_bad"
else
  ok "every projected skill has a loadable name and a description ($skills_checked skills: name: matches dsh-skill's grammar and the directory, description: non-empty)"
fi

# G. the vendored engine (spec 2026-09-26 §2) -- the engine is edited in scala-llm-template/kit/harness and
#    vendored by install.sh; a tree that no longer matches its STAMP was edited in place.
if dsh_is_vendored_engine "$engine" "$repo"; then
  case $(dsh_engine_stamp_verdict "$engine") in
    ok)       ok "vendored engine matches its STAMP (template $(dsh_engine_stamp_field "$engine" template))" ;;
    missing)  bad "$engine/STAMP is missing -- re-run install.sh from a scala-llm-template checkout: sh <scala-llm-template>/kit/harness/install.sh $repo" ;;
    mismatch) bad "vendored engine edited in place; edit in scala-llm-template/kit/harness and re-run install.sh from a scala-llm-template checkout" ;;
    nohasher) bad "no sha256 tool (shasum or sha256sum): the vendored engine cannot be compared with its STAMP" ;;
  esac
  [ "$(dsh_engine_stamp_field "$engine" dirty)" = 1 ] && note "the engine was vendored from an uncommitted template (STAMP dirty=1)"
  if [ -n "${SCALA_LLM_TEMPLATE:-}" ] && [ -d "$SCALA_LLM_TEMPLATE/kit/harness" ]; then
    # The template's tree carries the template-only paths (dsh_engine_template_only) and no STAMP; hash
    # a vendored-shaped copy, exactly as install.sh would build it, to compare like for like.
    th=$(dsh_engine_template_hash "$SCALA_LLM_TEMPLATE/kit/harness")
    [ "$th" = "$(dsh_engine_stamp_field "$engine" tree)" ] || note "the template at \$SCALA_LLM_TEMPLATE has moved ahead of the vendored engine -- re-run its install.sh to take it"
  fi
else
  note "check run from an unvendored engine at $engine -- no STAMP to compare (this is the template's own tree)"
fi

printf '\n%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
