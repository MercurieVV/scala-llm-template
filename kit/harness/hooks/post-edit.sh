#!/bin/sh
# Per-edit gate: the Mill module that owns an edited Scala file must pass the checks its own map row
# grants, in the same breath as the edit, so an agent cannot walk away from a violation it just
# introduced. It is the enforcement the rest of the harness exists for.
#
# It runs what `.dsh/engine/module-map.sh` grants for the file's module, and nothing else:
#
#   fmt       <module>.checkFormat
#   scalafix  <module>.fix --check
#             <module>.fixStrict
#   tests     <module>.test.compile    (only for a path under <module>/test/, and only when granted)
#   always    <module>.compile         (`compile` exists for every row, so an empty row means
#                                       "compile only" — `scalafixRules` and `wiring.details`)
#
# The module's checks are all run even after one has failed: the point is to hand back the whole
# picture in one breath. Every Mill invocation passes `--ticker false` (with the ticker on — the
# default even when stdout is a pipe — every line arrives prefixed with `<n>] `) and `--color false`
# (FORCE_COLOR is common in agent environments, and escape codes are noise in text an agent reads).
#
# Blocking rule (F53/F57) — only diagnostics naming a file this turn touched:
#
#   * the check names the edited file, by absolute path or by the root-relative spelling `compile`
#     emits -> BLOCK. Both spellings are accepted because checkFormat and fixStrict print absolute
#     paths while zinc prints `path:line:col` from the build root, and a root reached through a
#     symlink (a scratch root under /var) can make the absolute spelling differ from the one Mill
#     prints;
#   * the check names no source file at all -> BLOCK, because nothing in that text can be attributed
#     to someone else's change (a Mill-level failure with no diagnostic behind it);
#   * the check names only OTHER source files -> a note, never a block. Six of the repository's
#     modules are scalafmt-dirty today and `checkFormat` lists *every* misformatted file in a module,
#     so a block there would punish an agent for drift it did not cause and cannot fix from the file
#     it edited — F53's whole point. The same reading is applied to `fixStrict` and `compile`, whose
#     diagnostics are attributable too.
#
# `fix --check`, `fixStrict`, `compile` and `test.compile` run through `.dsh/engine/hooks/feedback.sh`
# (spec 2026-09-20 diagnostic→instruction): the agent is shown DIAGNOSTIC/INSTRUCTION lines rendered
# from the run, the raw log is kept under `.dsh/.state/feedback/`, and the blocking rule above reads
# that RAW log, never the rendered block — attribution has to see every path Mill printed, and the
# renderer folds them. That closes the hole this paragraph used to record: mill-scalafix's own failure
# line is generic ("A Scalafix linter error was reported"), but the log it sits in names every file a
# diagnostic is in, so `fix --check` and `fixStrict` are attributable per file like `compile` is. A
# block the adapters cannot read (UNREADABLE:/INFRA:) is shown raw, bounded like every section.
#
# Fail closed. A non-zero exit from the lookup is not "ungated": it means the gate cannot name the
# module that owns the file, so it denies with the lookup's own reason and says the build or its map
# is broken. The same for a lookup that exits 0 with something unreadable, and for a root with no
# Mill to run. Conversely, `-` (the map is present and owns nothing), a path that is not
# `.scala`/`.sc`, and a path that no longer exists (the edit deleted or moved it) are not this gate's
# business: they allow.
#
# The tool family is `write|edit|Write|Edit|MultiEdit` — a family, never a spelling, because DSH
# registers the lowercase tool names and Claude Code the capitalized ones and one gate.sh serves both
# (F64). `NotebookEdit` is deliberately NOT in that family even though Claude Code's matcher list here
# and the generated guard's tool list both name it: a notebook payload carries `notebook_path`, not
# `tool_input.file_path`, so this hook reads an empty path and exits 0 before it looks anything up.
# That is the correct verdict, not a gap — a notebook cannot be a `.scala`/`.sc` source, and this gate
# decides about nothing else. The matcher entry exists for vocabulary consistency with that guard; the
# no-op is asserted in `.dsh/engine/tests/vocabulary-test.sh`, so it stays a decision rather than an accident.
#
# Mill is invoked as `./mill` from the root — the repository's own wrapper, pinned to the build's
# Mill version, and the same thing `.dsh/engine/module-map.sh` runs — falling back to `mill` on PATH when
# there is no wrapper. The fallback is what makes the fixture cases hermetic: a scratch root has no
# `./mill`, so the `mill` stub first on PATH is the one that runs, and the wrapper branch is what a
# case exercises when it ships its own `./mill`.
#
# Never mutates: `checkFormat`, `fix --check`, `fixStrict` and `compile` write nothing. `reformat` and
# a bare `fix` rewrite the tree (`preCommit` reformats in place) and the gate must never call them —
# the remedy line asks the *agent* to run them.
#
# The skip cache: `.dsh/.state/green/<module>` records `<sha256>  <path>` TAB `<capabilities>` from
# the last run the gate allowed, so a repeated hook call for an unchanged file costs no Mill time.
# The path is part of the record because a module-wide hash alone would let a second, byte-identical
# file inherit the first file's verdict, and the capabilities are part of it because a verdict is
# only good for the task set it was reached with: a row that later grants `scalafix` must be checked
# again even though the file's bytes did not change.
#
# POSIX sh only: no arrays, no `local`, no `set -e`. Exit 0 allows, exit 2 blocks (`deny`).
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/lib.sh"

root=$(gate_root)

# --- the tool and the path this gate is for ------------------------------------------------
case "$(payload_get tool_name)" in
  write|edit|Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

path=$(payload_get tool_input.file_path)
[ -n "$path" ] || exit 0
# A relative file_path is resolved against the gate root, which is how the hooks receive it.
case "$path" in
  /*) ;;
  *) path="$root/$path" ;;
esac
case "$path" in
  *.scala|*.sc) ;;
  *) exit 0 ;;
esac
[ -f "$path" ] || exit 0

# A project with positive evidence of another build tool (plan ruling, spec §3): the engine's checks are
# Mill tasks, so it stands down, named, instead of blocking on "no Mill". It sits before the module-map
# lookup, not beside `resolve_mill`, because that lookup already runs ./mill and fails closed.
if nm=$(dsh_non_mill_build "$root"); then
  allow "DSH gate: gate engine supports Mill builds only; found: $nm -- checks stand down for this turn"
fi

# `pwd` is logical in dash and in bash, so a root or a file spelled through a symlink (/tmp and /var
# on macOS are symlinks) would not match the absolute paths Mill prints. module-map.sh canonicalises
# both sides the same way, so the path looked up here is the path that gets answered.
root=$(CDPATH= cd -- "$root" 2>/dev/null && pwd -P) || root=$(gate_root)
pdir=$(CDPATH= cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || pdir=""
if [ -n "$pdir" ]; then path="$pdir/$(basename -- "$path")"; fi
rel=${path#"$root"/}
if [ "$rel" = "$path" ]; then rel=""; fi
if [ -n "$rel" ]; then shown="$rel"; else shown="$path"; fi

# --- which module owns the file, and what that module may be asked to do -------------------
st=$(state_dir)
tab=$(printf '\t')
tmp=$(mktemp 2>/dev/null) || tmp=""
if [ -z "$tmp" ]; then tmp=${TMPDIR:-/tmp}/dsh-post-edit.$$; fi
ctmp=""
trap '[ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null; [ -n "$ctmp" ] && rm -f "$ctmp" 2>/dev/null; :' 0

lookup=$(sh "$here/module-map.sh" "$path" 2>"$tmp")
lookup_code=$?
reason=$(cat "$tmp" 2>/dev/null)

if [ "$lookup_code" != 0 ]; then
  deny "BLOCKED by the DSH gate: $shown cannot be checked — the module map could not decide which module owns it.
$reason
The build or its map is broken, and this gate fails closed rather than skipping a Scala edit: run ./mill --ticker false moduleMap by hand, fix what it reports, then edit again."
fi
[ "$lookup" = "-" ] && exit 0

module=$(printf '%s\n' "$lookup" | cut -f1)
caps=$(printf '%s\n' "$lookup" | cut -f2)
if [ -z "$module" ]; then
  deny "BLOCKED by the DSH gate: $shown cannot be checked — the module map answered with something this gate cannot read: [$lookup].
The map at $st/modules.tsv is malformed; run ./mill --ticker false moduleMap by hand and fix what it reports, then edit again."
fi

# `has_cap` — is <capability> one of this row's comma-separated tokens — comes from lib.sh: the
# turn-end gate asks the same question of the rows it reads, and M3 moved the copy there so the two
# answers cannot drift apart. `caps` is set just above.

# A path under the module's own `test/` directory: that is the shape the `tests` token is written in
# (`<id>.test.compile` for a path under `<dir>/test/`), and `checkFormat`/`fix` cover the main sources
# only, so it is the compile of the test submodule that checks such a file.
moddir=$(awk -F"$tab" -v m="$module" '$2 == m { print $1; exit }' "$st/modules.tsv" 2>/dev/null)
case "$moddir" in
  ''|.) test_rel="$rel" ;;
  *) test_rel=${rel#"$moddir"/} ;;
esac
is_test=0
case "$test_rel" in test/*) is_test=1 ;; esac

# --- the last allowed run for this exact file ----------------------------------------------
green="$st/green"
cache="$green/$(printf '%s' "$module" | tr '.' '_')"
hash=""
if command -v shasum >/dev/null 2>&1; then
  hash=$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
  hash=$(sha256sum "$path" 2>/dev/null | awk '{print $1}')
fi
# `<sha256>  <path>` TAB `<capabilities>`: a verdict is only good for the task set it was reached
# with, so a map row that later grants `scalafix` (or `fmt`) has to be re-checked even while the
# file's bytes — and therefore the hash — stay exactly the same. The path is in the record because a
# module-wide key would let a second, byte-identical file inherit the first file's verdict.
record="$hash  $path$tab$caps"
if [ -n "$hash" ] && [ -f "$cache" ] && [ "$(cat "$cache" 2>/dev/null)" = "$record" ]; then
  exit 0
fi

# --- Mill, and where it must run from ------------------------------------------------------
# `resolve_mill` (lib.sh, M3) is the shared rule: the repository's own wrapper when it is an
# executable file, else a `mill` on PATH. Both gates resolve it the same way, so a scratch root
# without a wrapper is checked by the stub either way.
mill=$(resolve_mill "$root") || mill=""
if [ -z "$mill" ]; then
  deny "BLOCKED by the DSH gate: $shown cannot be checked — there is no Mill to run the checks for $module with, neither $root/mill (the repository's own wrapper) nor a mill on PATH.
Install Mill (or restore the wrapper), then edit again; this gate fails closed rather than checking nothing."
fi
cd "$root" 2>/dev/null || deny "BLOCKED by the DSH gate: $shown cannot be checked — the gate root $root cannot be entered, so no check for $module can run.
Fix the root, then edit again; this gate fails closed rather than checking nothing."

# --- run them, and decide ------------------------------------------------------------------
blocked=0
noted=0
nchecks=0
report=''
notes=''
message=''
max_lines=15
max_report_bytes=4000
max_notes_bytes=2000

# `bound_bytes` (the byte bound every section and the whole report are cut to) and `bound_lines` (the
# per-section line bound) live in lib.sh: the turn-end gate hands back the same kind of text, and
# F59/F62 ask for one implementation rather than two copies of a logic block. `names_file` is shared
# for the same reason — and because both copies of that pipeline had the same EPIPE defect, which the
# shared one no longer has. `section`, which appends one bounded section to `report`/`notes` under
# the `max_lines` set above, is shared for that reason too (M3).

# check <label> <mill task...>: run one check, then classify a failure by what its output names.
check() {
  _label=$1
  shift
  nchecks=$((nchecks + 1))
  # `compile`, `fix --check`, `fixStrict` and `test.compile` speak in diagnostics, so they run through
  # the feedback wrapper via lib.sh's `dsh_check_through_wrapper` (one implementation, shared with
  # turn-end): the agent reads DIAGNOSTIC/INSTRUCTION lines (DSH_CHECK_SHOWN -- the raw text when the
  # block is UNREADABLE:/INFRA:), the raw log stays under .dsh/.state/feedback/, and the blocking
  # decision below still reads the RAW text (DSH_CHECK_RAW: F53 attribution must see every path Mill
  # printed, including the ones the renderer folded). checkFormat's output is a file list, not
  # diagnostics, and stays raw.
  case "$_label" in
    *.checkFormat)
      _out=$("$mill" --ticker false --color false "$@" 2>&1)
      _code=$?
      _raw=$_out ;;
    *)
      dsh_check_through_wrapper "$_label" "$mill" "$@"
      _code=$DSH_CHECK_RC
      _raw=$DSH_CHECK_RAW
      _out=$DSH_CHECK_SHOWN ;;
  esac
  [ "$_code" = 0 ] && return 0
  _mine=0
  case "$_raw" in
    *"$path"*) _mine=1 ;;
  esac
  if [ "$_mine" = 0 ] && [ -n "$rel" ]; then
    case "$_raw" in
      *"$rel"*) _mine=1 ;;
    esac
  fi
  _names=0
  if names_file "$_raw" 'scala|sc|java'; then _names=1; fi
  if [ "$_mine" = 1 ]; then
    blocked=$((blocked + 1))
    section blocking "$_label (failed; names the edited file)" "$_out"
  elif [ "$_names" = 0 ]; then
    blocked=$((blocked + 1))
    section blocking "$_label (failed; names no source file, so nothing there is attributable to another change)" "$_out"
  else
    noted=$((noted + 1))
    section note "$_label (failed; names only other files — not blocking)" "$_out"
  fi
  return 0
}

has_cap fmt && check "$module.checkFormat" "$module.checkFormat"
has_cap scalafix && check "$module.fix --check" "$module.fix" --check
has_cap scalafix && check "$module.fixStrict" "$module.fixStrict"
check "$module.compile" "$module.compile"
if [ "$is_test" = 1 ]; then
  has_cap tests && check "$module.test.compile" "$module.test.compile"
fi

# fastTests (spec 2026-09-20 §2): the contract's fast selection for this module, through the
# feedback wrapper. Red is NOTED, never blocking -- a failing property mid-edit is what TDD looks
# like, and this gate exists to catch drift, not to hold an agent hostage to its own red test.
# A red fastTests run is counted in `fb_noted`, not `noted`: the F53 summary below speaks of checks
# that failed on files this turn did not touch, and this module's own red test is not one of those.
ft_green=''; fb_noted=0; ft_notes=''
if has_cap tests && ft=$(dsh_contract_for_module fastTests "$module" "$root"); then
  ft_out=$(sh "$here/hooks/feedback.sh" --selector "$module.test" -- sh -c "$ft" 2>&1)
  ft_rc=$?
  if [ "$ft_rc" = 0 ]; then
    ft_green="fastTests: $module green"
  else
    fb_noted=1
    ft_notes="--- fastTests: $module (failed — noted, not blocking) ---
$(bound_lines "$ft_out" "$max_lines")"
  fi
fi

if [ "$blocked" -gt 0 ]; then
  remedy='fix the diagnostics above'
  if has_cap scalafix && has_cap fmt; then
    remedy="run ./mill $module.fix and ./mill $module.reformat"
  elif has_cap scalafix; then
    remedy="run ./mill $module.fix"
  elif has_cap fmt; then
    remedy="run ./mill $module.reformat"
  fi
  # Bounded once per section above and once as a whole here, so a module whose every check fails
  # still cannot hand back hundreds of lines or hundreds of kilobytes.
  report=$(bound_bytes "$report" "$max_report_bytes")
  deny "BLOCKED by the DSH gate: $module failed $blocked of $nchecks checks for $shown.
$report

Fix now: $remedy, then re-read the changed file (annotated_source) before editing it again. The gate runs on every Scala write and the turn-end gate re-checks it before the turn may end."
fi

if [ "$noted" -gt 0 ]; then
  notes=$(bound_bytes "$notes" "$max_notes_bytes")
  message="DSH post-edit: $module is clean for $shown, but $noted of $nchecks checks failed on files this turn did not touch — noted, not blocking (F53):
$notes

Those files were already in that state before this edit; fix them only if they are yours."
fi
if [ "$fb_noted" -gt 0 ]; then
  ft_notes=$(bound_bytes "$ft_notes" "$max_notes_bytes")
  ft_msg="DSH post-edit: $module is clean for $shown; its fastTests are red — noted, not blocking (a red property mid-edit is what TDD looks like):
$ft_notes"
  if [ -n "$message" ]; then message="$message
$ft_msg"; else message="$ft_msg"; fi
fi

if [ -n "$ft_green" ]; then
  if [ -n "$message" ]; then message="$message
$ft_green"; else message="$ft_green"; fi
fi

# The verdict is cached only for a file the gate just allowed, and only when a hash was available:
# without one, "unchanged since last time" cannot be claimed at all.
if [ -n "$hash" ]; then
  mkdir -p "$green" 2>/dev/null
  ctmp="$green/$(basename -- "$cache").$$"
  if printf '%s\n' "$record" 2>/dev/null > "$ctmp" && mv -f "$ctmp" "$cache" 2>/dev/null; then
    ctmp=""
  else
    rm -f "$ctmp" 2>/dev/null
    ctmp=""
  fi
fi

allow "$message"
