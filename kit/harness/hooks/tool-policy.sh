#!/bin/sh
# Denies the tools this repository must not use, whatever the sandbox mode allows.
# `sbt` is dead here (Mill is the build); scala-cli and javac stay available for
# ad-hoc kernels and classfile inspection.
# It also denies the operand-shaped commands when an OPERAND names a FROZEN PATH — the human's
# in-flight work (lib.sh: dsh_frozen_reason): rm, mv, ln, truncate, patch, `git checkout|restore|rm|
# mv|apply`, `perl -i` and `find -delete` / `find -exec rm`. Those commands are writes the semantic
# guard's write shapes cannot see (`rm` writes nothing a redirection would name, `mv`'s destination
# may be a whole directory, `git checkout -- <path>` is a revert), so this is the layer that answers
# for them, with the freeze's own reason — and a relative operand is resolved against a literal `cd`
# directory earlier on the line, because `cd engine/details && rm -rf src` deletes the human's work
# without naming it.
# It also denies running the SEALED holdout suite through Mill (`./mill holdout.test`, `__.test`,
# `prePush`, `show holdout.test.sources`): the gate runs that suite at turn-end and reports names only.
# Text, not shell semantics, but wrappers are seen through WITH their own options (`timeout 600 …`, `env FOO=1 …`,
# `nice -n 5 …`, `sudo -u root …`), and the code given to `eval` / `sh -c` is judged as a command of its own; a
# command the shell computes at run time (`sh -c "$CMD"`) is refused. A substitution in argument position
# (`echo $(git push --force)`) is still not detected, so this is one layer of four, not a sandbox.
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/lib.sh"

# Call it in a pipeline or `$( )`: words leave on stdout, the caller's `$@` and `IFS` are left as they were (only `_cpw_*` stays set), and the splitting runs under `set -f`, so a glob in command position cannot expand into the argument list.
# Print the name of each shell segment's command word in $1, one line per segment, after
# skipping leading wrappers and grouping; empty segments print nothing. Segments are split on
# `;`, `&&`, `||`, `|`, newlines, and on `&` followed by whitespace or end of line (`a & b`
# splits; a query string's `&b` does not). The wrappers are sudo, env, time, nohup, command,
# exec, xargs, do, then, else, if, while, until, and a segment may open with `(` or `{`. The
# word is a basename with surrounding `(` `{` `)` `}` and quotes removed, so `(./sh)` reports
# `sh`. Words are returned as data — the caller decides — so no `exit` ever runs inside the
# pipeline's subshell.
command_position_words() {
  _cpw_nl='
'
  # `&` ends a segment only where a shell would end one — before whitespace or the end of the
  # line — so a quoted query string (`"…?a=1&b=2"`) stays inside its segment.
  _cpw_segments=$(printf '%s' "${1:-}" | sed -e "s/&&/\\${_cpw_nl}/g" -e "s/||/\\${_cpw_nl}/g" \
    -e "s/;/\\${_cpw_nl}/g" -e "s/|/\\${_cpw_nl}/g" \
    -e "s/&\([[:space:]]\)/\\${_cpw_nl}\1/g" -e "s/&$/\\${_cpw_nl}/")
  # The for-loop's word list is expanded once, so IFS may be restored inside the body.
  _cpw_ifs=$IFS
  IFS=$_cpw_nl
  # Splitting runs with globbing off: with a file named `sbt` in the cwd, a literal `*` in
  # command position would otherwise expand to it and the hook would judge a command nobody
  # wrote. `$-` is the caller's, so it is restored rather than cleared.
  _cpw_dash=$-
  set -f
  for _cpw_segment in $_cpw_segments; do
    IFS=$_cpw_ifs
    set -- $_cpw_segment
    # A wrapper is skipped together with ITS OWN options (spec: the wrapper bypass): `env FOO=1`,
    # `env -i`/`-u NAME`, `timeout [-s SIG] [-k DUR] DURATION`, `nice -n 5`, `time -p`, `sudo -u root`,
    # `stdbuf -oL`, `exec -a NAME`, `busybox <applet>`, and chains of them. Before this, only the bare
    # wrapper NAME was skipped, so its first option became the "command" and `timeout 600 ./mill
    # holdout.test` reached the sealed suite. A leading `NAME=value` assignment is skipped the same way.
    # Options that take a separate value are listed per wrapper; any other `-…` word is a flag or an
    # option with its value attached (`-n5`, `-oL`, `--signal=KILL`). `command -v`/`-V` only LOOKS a
    # command up, so the walk stops there and the word reported is the option, not the name looked up.
    while [ $# -gt 0 ]; do
      case "$1" in
        [A-Za-z_]*=*)
          case "${1%%=*}" in *[!A-Za-z0-9_]*) break ;; esac
          shift ;;
        sudo|env|time|nohup|command|exec|xargs|nice|timeout|stdbuf|ionice|busybox)
          _cpw_w=$1
          shift
          while [ $# -gt 0 ]; do
            case "$_cpw_w:$1" in
              *:--) shift; break ;;
              command:-v|command:-V) break 2 ;;
              sudo:-[ughpCrtUD]|env:-[uCS]|time:-[of]|nice:-n|timeout:-[sk]|stdbuf:-[ioe]|xargs:-[IinPLsdEaJR]|exec:-a|ionice:-[cnp])
                shift
                [ $# -gt 0 ] && shift ;;
              *:-*) shift ;;
              *) break ;;
            esac
          done
          # timeout's own positional argument, the DURATION, comes before the command it runs.
          if [ "$_cpw_w" = timeout ] && [ $# -gt 0 ]; then shift; fi ;;
        do|then|else|if|while|until|'{'|'(') shift ;;
        *) break ;;
      esac
    done
    if [ $# -gt 0 ]; then
      _cpw_word=$1
      # Grouping and quoting in command position are punctuation, not part of the name:
      # `(curl`, `{ curl`, `(./sh)` and `"sh"` all name the command they wrap.
      while :; do
        case "$_cpw_word" in
          '('*|'{'*|'"'*|"'"*) _cpw_word=${_cpw_word#?} ;;
          *) break ;;
        esac
      done
      case "$_cpw_word" in
        */*) _cpw_word=${_cpw_word##*/} ;;
      esac
      while :; do
        case "$_cpw_word" in
          *')'|*'}'|*'"'|*"'") _cpw_word=${_cpw_word%?} ;;
          *) break ;;
        esac
      done
      if [ -n "$_cpw_word" ]; then printf '%s\n' "$_cpw_word"; fi
    fi
  done
  IFS=$_cpw_ifs
  case "$_cpw_dash" in *f*) ;; *) set +f ;; esac
}

# git_scan <args...>: sets _gs_sub to git's subcommand and _gs_next to the first non-option word
# after it. git's own global options come BEFORE the subcommand and some of them take a value
# (`-c <k=v>`, `-C <dir>`, `--git-dir=<dir>`), so a caller that read `$1` would see the option, or
# its value, as the subcommand and miss the command entirely -- measured: `git -c core.pager=cat
# checkout -- <frozen>` and `git -C /tmp checkout -- <frozen>` were both allowed. The option forms
# this knows are listed below; ANOTHER form is skipped as a bare flag, which is the documented blind
# spot (the same wrapper-option class the read guard names for `bash -c 'sbt …'`).
git_scan() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -c|-C|--git-dir|--work-tree|--namespace|--exec-path|--config-env)
        if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|--config-env=*) shift ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  _gs_sub=${1:-}
  [ $# -gt 0 ] && shift
  _gs_next=''
  while [ $# -gt 0 ]; do
    case "$1" in -*) shift ;; *) _gs_next=$1; break ;; esac
  done
}

# The whole-tree verdict: these commands rewrite the working tree rather than the paths they name,
# so there is no operand to decide -- and with a freeze in place the human's in-flight files are
# exactly what they would rewrite.
deny_whole_tree() { # <git subcommand>
  printf 'BLOCKED by tool-policy: `git %s` rewrites the working tree (or a whole directory) rather than\n' "${1:-...}" >&2
  cat >&2 <<'MSG'
the paths it names, and .dsh/frozen-paths holds at least one frozen path — in this repository that
means the human's in-flight files, which the freeze exists to protect. `git checkout -- .` and
`git restore .` discard every modified file, `git clean -fd` deletes the untracked ones, `git stash`
(push) and `git reset --hard` rewrite what is there.
Two ways out:
  1. operate on explicit paths — `git checkout -- engine/shape/src/A.scala`, `git clean -fd out/` —
     which the frozen-path rule then decides one by one;
  2. if the frozen work really should be discarded, the HUMAN removes the entry from
     .dsh/frozen-paths (committed) or .dsh/.state/frozen-paths (machine-local) first.
With no frozen path configured this command is not refused: the rule exists to protect a freeze, not
to ban the command, and `git stash list`, `git stash show` and every dry run (`-n`, `--dry-run`) are
allowed in any case.
MSG
  exit 2
}

# A family, never a spelling: DSH registers the lowercase tool names and Claude Code the
# capitalized ones, and one gate.sh serves both, so `bash` and `Bash` must decide alike (F64).
# Until this was a case, `Bash` -- every command a Claude Code session runs -- exited 0 here and
# the sbt denial below never fired there; `.dsh/engine/tests/vocabulary-test.sh` now sends both spellings
# of the same call and requires the same verdict, so the gap cannot reopen.
case "$(payload_get tool_name)" in
  bash|Bash) ;;
  *) exit 0 ;;
esac
cmd=$(payload_get tool_input.command)
[ -n "$cmd" ] || exit 0

# The frozen-path verdict for an operand-shaped command. The guarantee is stated exactly, in the
# discipline C-9 uses: the routes this gate can see are listed, and the classes it cannot see are
# named as outside it -- so no agent reads "no agent may make one" as covering a path built at run
# time or an interpreter that opens the file itself.
deny_frozen_operand() { # <path as the call spelled it> <reason>
  _do_access=$(dsh_frozen_access "${1:-}" 2>/dev/null || printf frozen)
  _do_word=FROZEN; [ "$_do_access" = sealed ] && _do_word=SEALED
  printf 'BLOCKED by tool-policy: %s is a %s PATH — the human is working on it right now.\n  reason: %s\n' \
    "$(bound_bytes "${1:-}" 240)" "$_do_word" "$(bound_bytes "${2:-}" 300)" >&2
  cat >&2 <<'MSG'
This command writes the paths it names as operands: rm, mv, ln, truncate, patch,
git checkout|restore|rm|mv|apply, perl -i, find -delete and find -exec rm — deleting, moving,
restoring or rewriting the human's in-flight work is a write, and no agent may make one.
OUTSIDE this layer, by construction — it matches spellings, never meaning:
  * a path built at run time (`rm "$f"`);
  * an interpreter that opens the file itself (python3 -c "open(p,'w')");
  * a patch whose target lives only inside the patch text (git apply /tmp/p.diff, patch < p.diff);
  * a symlinked spelling of the path (nothing here follows a link);
  * a git global option this layer does not know — it reads -c, -C, --git-dir, --work-tree,
    --namespace, --exec-path and --config-env before the subcommand, and skips another form as a
    bare flag, the same wrapper-option class the read guard names for `bash -c 'sbt …'`.
READS STAY ALLOWED (annotated_source, read/grep/glob). To let an agent change it, the HUMAN removes
the entry from .dsh/frozen-paths (committed) or .dsh/.state/frozen-paths (machine-local) first.
MSG
  exit 2
}

# The interpreter/inline-shell text verdict (spec 2026-09-28 §2). `deny_frozen_operand` above names
# this exact gap in its own OUTSIDE list -- "an interpreter that opens the file itself" -- because an
# interpreter's write is not an operand any shell-level rule can see. This is text, not semantics: it
# fires because the frozen path's SPELLING appears somewhere in the command text the interpreter or
# inline shell will run, never because anything here parsed what the program actually does.
deny_frozen_interp() { # <path as it appeared> <reason> <access>
  _di_word=FROZEN; [ "${3:-}" = sealed ] && _di_word=SEALED
  printf 'BLOCKED by tool-policy: %s is a %s PATH — the human is working on it right now.\n  reason: %s\n' \
    "$(bound_bytes "${1:-}" 240)" "$_di_word" "$(bound_bytes "${2:-}" 300)" >&2
  cat >&2 <<'MSG'
This command runs an interpreter or an inline shell (python/python2/python3/perl/ruby/node with any
arguments, sh/bash/zsh/dash with -c, or awk writing via `print >`/`printf >`/`system(`), and the
command's own text names a frozen path — an interpreter can write where the shell rules cannot see,
so this is refused before it runs, not after.
To read the file, use the Read tool (allowed) — reading is not what this rule exists to stop. To
change a frozen file, ask the human: the HUMAN removes the entry from .dsh/frozen-paths (committed)
or .dsh/.state/frozen-paths (machine-local) first.
NOT covered here (documented; the turn-end post-hoc check is the layer that answers for these): a
path the interpreter computes at run time, and an interpreter run from a script file rather than
inline.
MSG
  exit 2
}

# _it_boundary_match <needle>: exit 0 when <needle> occurs in $cmd as a PATH TOKEN -- not merely as
# a substring of a longer name. Fix round 1, item 1 (measured): the original rule appended a
# trailing `/` to a prefix row's spelling and searched for THAT, so a bare `engine/details` with no
# trailing slash (`rm -rf engine/details`, `shutil.rmtree('engine/details')`) matched no candidate at
# all and passed -- deleting the whole frozen tree. The fix is the same "word boundary" a text search
# always needs: <needle> counts only when whatever comes before it (if anything) and whatever comes
# after it (if anything) is NOT a path character -- so `engine/details_old` stays allowed (`_` is a
# path character, in the same set a shell accepts unquoted in a bare word) while `engine/details`,
# `engine/details/x`, `engine/details'` and `engine/details"` all count. The same rule now covers
# EXACT rows too, at both ends (fix round 1, item 1's last sentence): a frozen exact path is a whole
# name, never a fragment of a longer one either way -- so this single check replaces the two separate,
# asymmetric loops the previous version had for `exact` and `prefix`, because with a boundary check a
# `prefix` row's own directory name IS the token to look for (its own trailing slash was only ever
# there to fake the boundary this function now checks properly).
# The four alternatives are the standard case-pattern "whole token" idiom: needle alone (both ends are
# the ends of $cmd), needle then a non-path character (right boundary only, needle starts at the very
# start of $cmd), a non-path character then needle (left boundary only, needle runs to the very end),
# and a non-path character on both sides. `"$1"` is always quoted, so it is matched LITERALLY, never
# reinterpreted as a glob -- a frozen entry can never contain a glob metacharacter anyway
# (dsh_frozen_paths rejects `*`/`?`/`[`), so this is belt and suspenders, not a requirement.
_it_boundary_match() { # <needle>
  case "$cmd" in
    "$1"|"$1"[!A-Za-z0-9._-]*|*[!A-Za-z0-9._-]"$1"|*[!A-Za-z0-9._-]"$1"[!A-Za-z0-9._-]*) return 0 ;;
  esac
  return 1
}

# check_frozen_interp_text: scans the WHOLE command text ($cmd) for a frozen path's spelling, once
# per hook call (`_it_scanned`), and denies on the first hit. A caller runs this only once it has
# decided the CURRENT segment is an interpreter or inline-shell shape -- but the text scanned is
# always $cmd in full, heredoc bodies included, because the spec's rule is "one interpreter segment
# anywhere in the command makes a frozen name anywhere in the command deny it", not "in this segment".
# Every spelling a frozen entry can appear under is tried: root-relative, `./`-prefixed, and absolute
# through EITHER root spelling (dsh_repo_relpath resolves both, because /tmp and /private/tmp name
# the same directory on macOS). `exact` and `prefix` rows are now the SAME check
# (`_it_boundary_match`, see above): a bare `kernels.tsv` still does not match a frozen
# `.dsh/policy/kernels.tsv` (the basename-only fixture is unaffected -- it never was about the
# boundary, it is about the full path never appearing at all), and `engine/details_old` still does
# not match a frozen `engine/details/**` (the boundary fixture, now for the RIGHT reason).
check_frozen_interp_text() {
  [ "$_it_scanned" = 0 ] || return 0
  _it_scanned=1
  _it_rows=$(dsh_frozen_paths "$(gate_root)" 2>/dev/null) || :
  [ -n "$_it_rows" ] || return 0
  _it_root=$(gate_root)
  _it_root_phys=$(CDPATH= cd -- "$_it_root" 2>/dev/null && pwd -P) || _it_root_phys=$_it_root
  _it_tab='	'
  _it_ifs=$IFS
  IFS='
'
  _it_hit_reason=''
  _it_hit_access=''
  _it_hit_path=''
  for _it_row in $_it_rows; do
    IFS=$_it_ifs
    _it_racc=${_it_row%%"$_it_tab"*}
    _it_rest=${_it_row#*"$_it_tab"}
    _it_kind=${_it_rest%%"$_it_tab"*}
    _it_rest=${_it_rest#*"$_it_tab"}
    _it_p=${_it_rest%%"$_it_tab"*}
    _it_creason=${_it_rest#*"$_it_tab"}
    case "$_it_kind" in
      exact|prefix)
        for _it_sp in "$_it_p" "./$_it_p" "$_it_root/$_it_p" "$_it_root_phys/$_it_p"; do
          if _it_boundary_match "$_it_sp"; then
            _it_hit_reason=$_it_creason; _it_hit_access=$_it_racc; _it_hit_path=$_it_p; break
          fi
        done ;;
    esac
    [ -n "$_it_hit_reason" ] && break
  done
  IFS=$_it_ifs
  if [ -n "$_it_hit_reason" ]; then
    deny_frozen_interp "$_it_hit_path" "$_it_hit_reason" "$_it_hit_access"
  fi
}

# The write side of the directory-change rule: this hook resolves a relative operand against the
# repository root, so an operand that follows a `cd` this layer cannot resolve is undecided -- and
# undecided is denied rather than guessed, because the guess is the permissive direction.
deny_undecided_operand() { # <operand as written>
  printf 'BLOCKED by tool-policy: this line CHANGES DIRECTORY and names a RELATIVE path (%s), so WHERE\n' \
    "$(bound_bytes "${1:-}" 240)" >&2
  cat >&2 <<'MSG'
this command acts cannot be decided: after a `cd`, a relative name resolves against that directory,
and this hook resolves against the repository root — so the same text can name a frozen path without
naming it here.
Two ways out:
  1. name the path from the repository root and drop the `cd`:
       rm -rf engine/details/src        (no `cd`, no subshell)
     the frozen-path rule then decides it exactly, with the entry's own reason;
  2. a frozen path is not released by anything here — the HUMAN removes the entry from
     .dsh/frozen-paths (committed) or .dsh/.state/frozen-paths (machine-local) first.
MSG
  exit 2
}

# A trailing backslash continues the command on the next line: join such lines before anything
# splits the line, or `curl … \` + newline + `| sh` reads as two commands and the pipe
# disappears. Plain shell on purpose — a missing `awk` must not be able to switch off detection.
_nl='
'
_joined=
while IFS= read -r _line; do
  case "$_line" in
    *\\) _joined="$_joined${_line%\\}" ;;
    *) _joined="$_joined$_line$_nl" ;;
  esac
done <<POLICY_END
$cmd
POLICY_END
cmd=$_joined

# CODE GIVEN TO AN INTERPRETER AS TEXT (spec: the wrapper bypass): `eval '…'` and a shell given `-c`
# (`sh -c '…'`, `bash -lc '…'`, any flag cluster holding `c`) run text this file would otherwise see
# only as an argument, so `sh -c "./mill holdout.test"` reached the sealed suite. That text is lifted
# out and APPENDED to the line as further lines, so every rule below judges it as a command of its
# own; quote characters are dropped from it (deny direction only: more text judged, never less), and
# the lift repeats for nested forms, up to three levels. Text whose command word the shell computes
# at run time (`sh -c "$CMD"`, `eval "$(cat run.sh)"`, a backquote) cannot be judged as text at all,
# so it is refused rather than allowed.
inline_code_of() { # <text>: prints the code each `eval` / `<shell> -c` segment runs, one per line
  _ic_segs=$(printf '%s' "$1" | sed -e "s/&&/\\${_nl}/g" -e "s/||/\\${_nl}/g" -e "s/;/\\${_nl}/g" \
    -e "s/|/\\${_nl}/g" -e "s/&\([[:space:]]\)/\\${_nl}\1/g" -e "s/&$/\\${_nl}/")
  _ic_ifs=$IFS
  IFS=$_nl
  for _ic_seg in $_ic_segs; do
    IFS=$_ic_ifs
    _ic_word=$(command_position_words "$_ic_seg")
    [ -n "$_ic_word" ] || continue
    set -- $_ic_seg
    # Step past the wrappers AND their own options (`nice -n 5`, `timeout 5`, `sudo -u x`) to the
    # interpreter word itself: stopping at the first word whose command position differs left
    # `nice -n 5 eval '…'` lifted as `-n 5 eval …`, whose command word is `-n` (measured live).
    while [ $# -gt 0 ]; do
      case "$1" in
        "$_ic_word"|*/"$_ic_word")
          if [ "$(command_position_words "$*")" = "$_ic_word" ]; then shift; break; fi ;;
      esac
      shift
    done
    case "$_ic_word" in
      eval) ;;
      sh|bash|zsh|dash|ksh|ash|mksh)
        _ic_c=0
        while [ $# -gt 0 ]; do
          case "$1" in
            --*) shift ;;
            -*c*) shift; _ic_c=1; break ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        [ "$_ic_c" = 1 ] || continue ;;
      *) continue ;;
    esac
    [ $# -gt 0 ] || continue
    printf '%s\n' "$*" | tr -d "\"'"
  done
  IFS=$_ic_ifs
}
_ic_dash=$-
set -f
_ic_more=$cmd
_ic_depth=0
while [ "$_ic_depth" -lt 3 ]; do
  _ic_more=$(inline_code_of "$_ic_more")
  [ -n "$_ic_more" ] || break
  _ic_cw=$(command_position_words "$_ic_more")
  case "$_ic_cw" in
    *'$'*|*'`'*)
      case "$_ic_dash" in *f*) ;; *) set +f ;; esac
      deny "BLOCKED by tool-policy: this gate cannot judge the command an interpreter would run here — its name is computed at run time ($(bound_bytes "$(printf '%s' "$_ic_cw" | tr '\n' ' ')" 120)).
Write the command out literally (no \`eval\`, no \`sh -c\` around a variable or a substitution), so the gate can read it." ;;
  esac
  cmd="$cmd$_ic_more$_nl"
  _ic_depth=$((_ic_depth + 1))
done
case "$_ic_dash" in *f*) ;; *) set +f ;; esac

# FROZEN PATHS: where a `cd`/`pushd` on this line sends a relative operand. Asked ONCE per call, and
# only for a line that has a `cd` at all -- the awk walk is not worth paying for `ls`, and a line
# with no `cd` has no base to resolve (lib.sh: dsh_bash_action_paths + dsh_bash_cd_base).
#   _fz_base_state 0 = resolved into $_fz_base, 2 = undecided, 1/3 = no base (root-relative stands).
# `2>/dev/null` on the printf is the established idiom for the EPIPE class (`grep -q` leaves the
# writer mid-stream), and lib-test's lint requires it.
_fz_base=''
_fz_base_state=1
if printf '%s' "$cmd" 2>/dev/null | grep -Eq '(^|[|;&(`]|[[:space:]])(cd|pushd)([[:space:]]|$)'; then
  _fz_rows=$(dsh_bash_action_paths "$cmd")
  if _fz_base=$(dsh_bash_cd_base "$_fz_rows" "$(gate_root)"); then
    _fz_base_state=0
  else
    _fz_base_state=$?
  fi
fi

# sbt is refused, and this is the one predicate that judges `command_position_words`' output as a
# whole: "is any command-position word sbt" is a fixed alternation over ONE word, so it is a `case`
# test over the words the helper printed — never a pipeline into `grep -qxE`. That pipeline was the
# function-boundary instance of the EPIPE class this branch keeps finding (F63): `grep -q` exits at
# the first match, so for a command longer than the pipe capacity the WRITER reports the broken pipe,
# and the agent reads shell noise instead of this denial (measured with SIGPIPE ignored, the
# disposition a hook inherits in production: a 180 KB command produced 5.88 MB on stderr while the
# exit code stayed 2). No reader, no pipe, no failure mode.
#
# The helper's output is split on newlines with globbing off, for the same reason the helper turns it
# off: an unquoted `*` in command position must not expand to the filenames in the cwd.
_cpw_dash=$-
_cpw_words=$(command_position_words "$cmd")
_cpw_ifs=$IFS
IFS=$_nl
case "$_cpw_dash" in *f*) ;; *) set -f ;; esac
_sbt=0
for _cpw_w in $_cpw_words; do
  case "$_cpw_w" in
    sbt|sbt-launch) _sbt=1; break ;;
  esac
done
IFS=$_cpw_ifs
case "$_cpw_dash" in *f*) ;; *) set +f ;; esac
if [ "$_sbt" = 1 ]; then
  deny "BLOCKED by tool-policy: this repository builds with Mill, not sbt.
  ./mill -j 1 preCommit      format + scalafix --check + fixStrict + compile
  ./mill <module>.<task>     e.g. ./mill engine.details.compile
scala-cli and javac are allowed for ad-hoc runs and classfile inspection."
fi

# THE REPOSITORY BOUNDARY (spec 2026-09-24 §3). A turn is a work-in-progress checkpoint; a commit is
# what the repository keeps. `git commit` and `./mill prePush` therefore run the diff-scoped check
# first, and there every FINDING blocks — including the prose ones that only note at turn-end. (A
# DEGRADATION note — "I could not check" — never blocks, at either boundary: verify-diff.sh's own
# header says why.) Turn-end protects the agent workflow; this protects the repository boundary.
# verify-diff.sh is resolved next to THIS script (the same `$0`-relative .dsh dir the sourcing line
# above uses), not via gate_root: gate_root is the fixture/GATE_ROOT world the script operates
# AGAINST (it does its own `cd "$(gate_root)"` internally), while the script itself always lives
# beside this hook, exactly like turn-end.sh's `$here/verify-diff.sh`.
#
# WORDS, never a substring. The old `case "$cmd" in *'git commit'*` both over- and under-matched,
# measured: `git commit-graph write`, `git commit --dry-run` and `echo "git commit later"` all fired,
# while `git -C sub commit -m x`, `./mill -j2 prePush` and `./mill --jobs 1 prePush` all slipped
# through. So this reads the command the way every other rule in this file reads it — segments from
# `command_position_words`, git's own global options walked by `git_scan` — and decides on the
# SUBCOMMAND (`commit`, never `commit-graph`) and on whole argument words. A dry run changes nothing,
# so `--dry-run` is not this boundary's business.
#
# WHICH TREE. `--staged` reads the index; that is right for `git commit -m x` and for `./mill
# prePush`. It is wrong for `git commit -a` / `-am` / `--all` / `--include` and for
# `git commit <path>`, which stage AFTER this hook has run: measured, with the change unstaged the
# gate read an empty index, exited 0 in silence, and the commit went through unchecked. Those forms
# get `--staged-worktree`, which reads `git diff HEAD` — what is staged plus what the commit is about
# to stage.
_vb=0
_vb_wt=0
_vb_dash=$-
_vb_ifs=$IFS
# Segments exactly as `command_position_words` cuts them, plus `|`, so each chain part is judged on
# its own: `cd x && git commit -m y` and `foo | git commit` both reach the walk below.
_vb_segs=$(printf '%s' "$cmd" | sed -e 's/;[[:space:]]*}//g' -e "s/&&/\\${_nl}/g" -e "s/||/\\${_nl}/g" \
  -e "s/;/\\${_nl}/g" -e "s/|/\\${_nl}/g" -e "s/&\([[:space:]]\)/\\${_nl}\1/g" -e "s/&$/\\${_nl}/" |
  sed -e 's/^[[:space:]]*[({]*//' -e 's/[)}]*[[:space:]]*$//')
case "$_vb_dash" in *f*) ;; *) set -f ;; esac
IFS=$_nl
for _vb_seg in $_vb_segs; do
  IFS=$_vb_ifs
  _vb_word=$(command_position_words "$_vb_seg")
  if [ -n "$_vb_word" ]; then
    # This segment's own arguments, left in $@ — the same shift-while-the-word-is-unchanged walk the
    # main loop below uses to step past the wrappers the helper skipped.
    set -- $_vb_seg
    while [ $# -gt 0 ] && [ "$(command_position_words "$*")" = "$_vb_word" ]; do shift; done
    case "$_vb_word" in
      git)
        git_scan "$@"
        if [ "$_gs_sub" = commit ]; then
          _vb_dry=0    # a dry run changes nothing, so it is not this boundary's business
          _vb_paths=0  # `git commit <path>` — stages that path after this hook has run
          _vb_all=0    # `-a` / `-am` / `--all` / `--include` — stages the working tree, ditto
          _vb_sawsub=0
          _vb_endopt=0
          _vb_prev=''
          _vb_q=''     # the quote character an unterminated quoted word opened, if any
          for _vb_a in "$@"; do
            # `set -- $seg` split on whitespace, so a quoted value arrives as several words. While a
            # quote is open every word belongs to that value — never a path, never an option — and
            # when it closes the whole value is behind us, so `_vb_prev` is cleared and the NEXT bare
            # word is judged as an operand again. Without this, `git commit -m "add it"` read `it"`
            # as a path operand and checked the whole working tree.
            if [ -n "$_vb_q" ]; then
              case "$_vb_a" in *"$_vb_q") _vb_q=''; _vb_prev='' ;; esac
              continue
            fi
            if [ "$_vb_sawsub" = 0 ]; then
              [ "$_vb_a" = commit ] && _vb_sawsub=1
              continue
            fi
            case "$_vb_a" in
              '"'*'"'|"'"*"'") : ;;
              '"'*) _vb_q='"' ;;
              "'"*) _vb_q="'" ;;
            esac
            if [ "$_vb_endopt" = 1 ]; then
              [ -n "$_vb_q" ] || _vb_paths=1
              continue
            fi
            case "$_vb_a" in
              --dry-run) _vb_dry=1 ;;
              --) _vb_endopt=1 ;;
              --all|--include|--interactive|--patch) _vb_all=1 ;;
              --*) ;;
              # The short options that CARRY a value, whether attached or not: whatever follows is
              # that value, not a flag cluster and not a path.
              -m*|-c*|-C*|-F*|-t*|-S*|-u*|-e*|-q*|-v*|-n*|-s*|-o*|-z*) ;;
              # A short cluster: `-a`, `-am`, `-ai`. Every letter is tested, because `-a` may ride
              # in front of another flag in the same word.
              -*) case "$_vb_a" in *a*|*i*|*p*) _vb_all=1 ;; esac ;;
              # A bare operand. The value of an option that takes one is not a path; anything else
              # is, and `git commit <path>` is exactly that shape.
              *) if [ -z "$_vb_q" ]; then
                   case "$_vb_prev" in
                     -m|--message|-c|-C|--reuse-message|--reedit-message|--file|-F|--author|--date|--template|-t|--cleanup|--gpg-sign|-S|--fixup|--squash|--trailer|--pathspec-from-file|-u|--untracked-files) ;;
                     *) _vb_paths=1 ;;
                   esac
                 fi ;;
            esac
            [ -n "$_vb_q" ] || _vb_prev=$_vb_a
          done
          if [ "$_vb_dry" = 0 ]; then
            _vb=1
            [ "$_vb_all" = 1 ] && _vb_wt=1
            [ "$_vb_paths" = 1 ] && _vb_wt=1
          fi
        fi ;;
      mill)
        for _vb_a in "$@"; do
          case "$(printf '%s' "$_vb_a" | tr -d "\"'")" in
            prePush) _vb=1 ;;
          esac
        done ;;
    esac
  fi
  IFS=$_nl
done
IFS=$_vb_ifs
case "$_vb_dash" in *f*) ;; *) set +f ;; esac

_vb_dsh=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$_vb" = 1 ] && [ -x "$_vb_dsh/verify-diff.sh" ]; then
  if [ "$_vb_wt" = 1 ]; then
    _vb_out=$(sh "$_vb_dsh/verify-diff.sh" --staged-worktree 2>&1)
  else
    _vb_out=$(sh "$_vb_dsh/verify-diff.sh" --staged 2>&1)
  fi
  if [ $? = 2 ]; then
    deny "BLOCKED by tool-policy: what this commit would keep names something that does not exist,
or breaks the module's symbol policy.
$_vb_out
A turn may end with a name that does not resolve yet; a COMMIT may not — this is what the repository
keeps. Fix what is named above, stage the fix, and commit again."
  fi
fi

# THE SEALED HOLDOUT SUITE, run through the build tool. The seal on `holdout/**` denies reading the
# suite's text; running it through Mill would print that text (assertion messages, diffs) straight
# back to the agent, and `__.test` / `prePush` / `show holdout.test.sources` reach it just as well
# as naming the module. So the target is derived here exactly as `dsh_holdout_checks` rule 2 does --
# the first dotted segment of the LAST word of the contract's `holdout =` line -- and, when the
# contract has that line, a `mill` command whose argument equals `<target>`, starts `<target>.`, or
# is one of the aggregate selectors that resolve into it, is refused. A contract without the line
# runs no holdout suite, so there is nothing to protect and the rule is skipped entirely.
_ho_target=''
if _ho_cmd=$(dsh_contract_get holdout 2>/dev/null) && [ -n "$_ho_cmd" ]; then
  _ho_sel=${_ho_cmd##* }
  _ho_target=${_ho_sel%%.*}
  [ -n "$_ho_target" ] || _ho_target=holdout
fi
deny_holdout_run() { # <selector as written>
  printf 'BLOCKED by tool-policy: %s runs the SEALED holdout suite — the gate runs it at turn-end; you read only the names it reports.\n' \
    "$(bound_bytes "${1:-}" 240)" >&2
  cat >&2 <<'MSG'
The holdout module is sealed (.dsh/frozen-paths): its sources are neither read nor edited by the
agent, and running it through the build tool would print its assertion text back here. The gate runs
the contract's `holdout =` command at turn-end and reports only the failing test NAMES.
Refused selectors: the holdout module itself (`<target>`, `<target>.*`, also after `show`/`resolve`),
and the aggregates that resolve into it: `__.test`, `__.test.<task>`, `_.test`, `__.testForked`,
`__.testCached`, `__.compile`, `__.testOnly`, `prePush`, and a brace form naming the module. Quotes
around a selector do not change what Mill runs, so they do not change the verdict.
`preCommit`, `moduleMap` and another module's `.test` stay allowed; compile one module with
`./mill <module>.compile` (`./mill resolve _` lists them).
MSG
  exit 2
}

# The three rules below judge words, never the raw line. They read the command in the shape
# `command_position_words` splits it into: a segment (one per line here) is a chain, and the
# pipes inside a segment cut that chain into parts. Segments break where the helper breaks them
# — `;`, `&&`, `||`, newline, and `&` only before whitespace or end of line — so a fallback
# (`a || b`) and a quoted query string both read correctly. A chain's own grouping is dropped
# here as the helper drops it from a command word, so `(git push --force)` still shows its flag
# in argument position and `{ curl …; } | sh` is still one chain — a brace group needs that `;`
# before its `}`, and reading it as a chain break would hide the pipe the group feeds. A part's
# command word comes from the helper; every other decision compares whole words in argument
# position, which is what keeps `git commit -m "…force-push…"` and `echo "rm -rf /etc"` out.
_segments=$(printf '%s' "$cmd" | sed -e 's/;[[:space:]]*}//g' -e "s/&&/\\${_nl}/g" -e "s/||/\\${_nl}/g" \
  -e "s/;/\\${_nl}/g" -e "s/&\([[:space:]]\)/\\${_nl}\1/g" -e "s/&$/\\${_nl}/" |
  sed -e 's/^[[:space:]]*[({]*//' -e 's/[)}]*[[:space:]]*$//' -e 's/$/|/')

# Globbing off for the same reason as in the helper: `set -- $_part` must not expand a `*` into
# filenames. `$-` is the caller's, and `deny` below exits from this shell, never a subshell.
_dash=$-
set -f
_ifs=$IFS
# The feedback rewrite, if the loop decides one; emitted only after every deny rule has run.
_fb_rewrite=''
# INTERPRETER TEXT RULE (spec 2026-09-28 §2): scanned at most once per hook call, on the first
# qualifying segment -- the target is always the WHOLE command text ($cmd), never the segment that
# tripped it, so a second qualifying segment would find nothing this one didn't already look at.
_it_scanned=0
IFS='
'
for _seg in $_segments; do
  IFS=$_ifs
  # One pipe part at a time. `_prev` is the command word of the part before it — inside this
  # chain only, since a chain break starts a new segment.
  _prev=
  _rest=$_seg
  while [ "${_rest#*|}" != "$_rest" ]; do
    _part=${_rest%%|*}
    _rest=${_rest#*|}
    _word=$(command_position_words "$_part")

    # Network installers: a download piped straight into a shell. The helper skips wrappers, so
    # `curl … | sudo bash` is seen through; `busybox` is listed because the applet it names is
    # the shell, and quoting in command position (`| "sh"`) is stripped by the helper too.
    case "$_prev" in
      curl|wget)
        case "$_word" in
          sh|bash|zsh|ksh|mksh|pdksh|dash|ash|fish|csh|tcsh|busybox)
            deny "BLOCKED by tool-policy: piping a network download into a shell is not allowed here.
Fetch to a file, inspect it, then run it deliberately." ;;
        esac ;;
    esac
    _prev=$_word

    # This part's own arguments, left in $@: shifting words off the front while the helper still
    # names the same command word lands right after the wrappers it skipped.
    set -- $_part
    while [ $# -gt 0 ] && [ "$(command_position_words "$*")" = "$_word" ]; do shift; done

    # INTERPRETER TEXT RULE (spec 2026-09-28 §2): is THIS part's command word an interpreter (any
    # arguments) or an inline shell (`-c` among its words), or is it `awk`/`gawk`/`mawk`/`nawk`
    # writing? Wrapper words the SHARED parser's own bare-word list skips (`sudo`, `env`, `time`,
    # `nohup`, `command`, `exec`, `xargs`, …) are already invisible here -- `command_position_words`
    # skipped them before `_word` was set, the same seam every other rule in this file reads through,
    # so `env python3 -c …` is covered without a new parser -- and since the wrapper-bypass fix that
    # parser also skips each wrapper's OWN options (`sudo -u x …`, `sudo -E …`, `env -i …`, `nice -n 5 …`
    # / `nice -n5 …`, `time -p …`, `xargs -I{} …`, `timeout 5 …`, `busybox <applet>`), so those are seen
    # through here too (measured: all denied for a frozen target).
    #
    # A PATH-QUALIFIED wrapper (fix round 1, item 5, measured: `/usr/bin/env python3 -c …` was
    # allowed while bare `env python3 -c …` was denied) is the one case the shared parser's wrapper
    # list does not see through: it matches wrapper NAMES exactly, so `/usr/bin/env` does not match
    # `env` and is treated as the command itself, basename-stripped to `env`. The shift loop just
    # above this comment already, as a side effect of always shifting at least once (its own first
    # comparison is against the unchanged input), leaves `"$@"` positioned at `python3 -c …` either
    # way -- so recomputing the word from `"$@"` when `_word` IS one of these wrapper basenames
    # recovers the real interpreter without touching the shared parser or `_word` itself (kept LOCAL
    # to this rule: no other rule in this file should start treating `/usr/bin/env git push --force`
    # as `git`, which is a wider change than this fix round asks for).
    _it_word=$_word
    case "$_it_word" in
      env|command|exec|nice|sudo|time|nohup|xargs)
        if [ $# -gt 0 ]; then
          _it_word2=$(command_position_words "$*")
          [ -n "$_it_word2" ] && _it_word=$_it_word2
        fi ;;
    esac
    # ASSIGNMENT-PREFIXED interpreter (final-review fix pass, I3a): `NAME=value cmd` is POSIX shell
    # syntax for a one-shot environment override, and it is invisible to everything above -- the
    # shared parser has no notion of assignment syntax (teaching it one would change every OTHER
    # rule in this file that reads through it, e.g. `git`'s force-push check, a wider change than this
    # rule asks for), so it reports the assignment word itself as the command word, and
    # `PYTHONPATH=. python3 -c …` / `A=1 B=2 sh -c …` both read as an unrecognised word and passed
    # (measured). Handled LOCALLY, the same way `/usr/bin/env` is just above: while the word looks
    # like `NAME=value` (NAME matching the POSIX shell variable-name grammar,
    # `[A-Za-z_][A-Za-z0-9_]*`), skip it and recompute the word from what is left, until the word is
    # not itself an assignment or nothing remains. The shift loop above already leaves `"$@"`
    # positioned right after `_it_word` either way, so each turn of this loop only needs to advance
    # past however many further words the recomputed word itself spans (its own shift loop, same
    # idiom), never re-deriving position from scratch.
    while :; do
      case "$_it_word" in
        *=*) _it_name=${_it_word%%=*} ;;
        *) break ;;
      esac
      case "$_it_name" in
        [A-Za-z_]*)
          _it_nrest=${_it_name#?}
          case "$_it_nrest" in
            *[!A-Za-z0-9_]*) break ;;
          esac ;;
        *) break ;;
      esac
      [ $# -gt 0 ] || break
      _it_word2=$(command_position_words "$*")
      [ -n "$_it_word2" ] || break
      _it_word=$_it_word2
      while [ $# -gt 0 ] && [ "$(command_position_words "$*")" = "$_it_word" ]; do shift; done
    done
    _it_interp=0
    case "$_it_word" in
      sh|bash|zsh|dash)
        # A COMBINED short-option cluster (fix round 1, item 2, measured: `bash -lc`, `sh -ec` and
        # `bash -xc` were all allowed) carries `-c` inside a cluster of other short flags, never as
        # its own word. `--*` is excluded first (a long option never bundles this way) so it can
        # never reach the broad `-c` cluster pattern below it. The pattern is a plain `-*c*`, not a
        # `[A-Za-z]`-anchored one: a bracket-expression term is exactly ONE character, so
        # `-[A-Za-z]*c[A-Za-z]*` (this file's first draft) requires a letter AFTER the `c` too and
        # therefore never matches `-c` or `-lc` themselves -- measured while writing this fix.
        for _it_a in "$@"; do
          case "$_it_a" in
            --*) ;;
            -*c*) _it_interp=1; break ;;
          esac
        done ;;
      awk|gawk|mawk|nawk)
        # The awk trigger (fix round 1, item 3, measured: `awk 'BEGIN{print "x" > "…"}'` and
        # `{print>"…"}` were both allowed) was too literal: it required the exact substrings
        # `print >`/`printf >` with a space. `system(` alone is still sufficient (it can run
        # anything); otherwise the program counts as writing when it contains `print` or `printf`
        # AND, separately and anywhere in the text, `>` or `|` -- not necessarily adjacent, and not
        # necessarily in that order, because `awk`'s own syntax does not require it (`> "f"` inside a
        # different block, `printf("%s", x) > f`, `print | "cmd"`).
        # Checked against $cmd, not $_part: the segment/part splitter above cuts on a literal `|`
        # ANYWHERE in the line, quoting or not (this whole file is text, not shell semantics -- see
        # its own header) -- so an awk program that uses `|` as ITS OWN operator
        # (`print $0 | "cat > f"`) is itself split into two "parts" by that `|`, and the half
        # holding `awk` would never see the `|` or whatever follows it in $_part. $cmd is whole and
        # is also what `check_frozen_interp_text` scans for the frozen path, so a false trigger from
        # an unrelated later segment (over-matching, not under-matching) is the same accepted
        # trade-off the whole-command path scan already makes.
        case "$cmd" in
          *'system('*) _it_interp=1 ;;
          *'print'*|*'printf'*)
            case "$cmd" in
              *'>'*|*'|'*) _it_interp=1 ;;
            esac ;;
        esac ;;
      *)
        # A version suffix on the basename is stripped before the comparison (`python3.12`,
        # `python2.7`, `pypy3`) by peeling trailing digit/dot characters one at a time -- a plain
        # `case … in python3.*)` cannot also match a bare `python3`. `pypy`, `nodejs` and `php` are
        # added here (fix round 1, item 5) alongside the original five names.
        _it_base=$_it_word
        while :; do
          case "$_it_base" in
            *[0-9.]) _it_base=${_it_base%?} ;;
            *) break ;;
          esac
        done
        case "$_it_base" in
          python|perl|ruby|node|pypy|nodejs|php) _it_interp=1 ;;
        esac ;;
    esac
    [ "$_it_interp" = 1 ] && check_frozen_interp_text

    # History rewriting: the command word is `git`, its first argument is `push`, and a force
    # flag is among the arguments.
    if [ "$_word" = git ] && [ "${1:-}" = push ]; then
      for _arg in "$@"; do
        case "$_arg" in
          -f|--force|--force-*)
            deny "BLOCKED by tool-policy: force-push is not allowed. Push a branch and open a PR." ;;
        esac
      done
    fi

    # THE SEALED HOLDOUT SUITE: the command word is `mill` (`./mill` is the same basename) and an
    # argument names the holdout module or an aggregate that reaches it (see deny_holdout_run).
    # Quote characters are punctuation, not part of the selector (`'holdout.test'`, `hold""out.test`
    # both spell `holdout.test` to Mill), so they are stripped before the match. `_.test` (direct
    # children) and `__.test.<task>` reach the suite as surely as `__.test`; a brace form
    # (`{holdout,app}.test`) is expanded by the shell, so a word merely CONTAINING the target between
    # brace punctuation is denied too. Text, not shell semantics: `bash -c '…'` and a selector built
    # from a variable stay outside this layer, as the README says.
    if [ "$_word" = mill ] && [ -n "$_ho_target" ]; then
      for _arg in "$@"; do
        _sel=$(printf '%s' "$_arg" | tr -d "\"'")
        case "$_sel" in
          "$_ho_target"|"$_ho_target".*|_.test|_.test.*|__.test|__.test.*|__.testForked|__.testCached|__.compile|__.testOnly|prePush)
            deny_holdout_run "$_sel" ;;
          "{"*"$_ho_target"*"}"*|*"{"*"$_ho_target"*"}"*)
            deny_holdout_run "$_sel" ;;
        esac
      done
    fi

    # FEEDBACK REWRITE (spec 2026-09-20 §2): the agent's own test/compile/fix run goes through the
    # wrapper, so the raw runner output never reaches it -- only the FEEDBACK block, with the raw
    # log's path. Only a bare Mill `.test`/`.test.*`/`testOnly`/`testForked`/`testCached`/`.compile`/
    # `.fix`/`.fixStrict` call is rewritten: a line the agent already composed into a pipeline, a
    # redirect, a sequence or a SECOND LINE is its own business, and an already-wrapped line is left
    # alone. "Single segment" is tested against the WHOLE line ($cmd, trimmed of the trailing newline
    # the join loop above always appends) rather than a segment counter, because the separator
    # characters that would make this a pipeline/sequence/redirect can appear anywhere on the line,
    # not only inside the part `command_position_words` is currently looking at. A newline inside the
    # trimmed text is a separator like `;` -- wrapping a two-line command would hand line 2 to the
    # wrapper's `sh -c` unjudged.
    # The rewrite is DECIDED here and EMITTED after the loop (`_fb_rewrite`, below): an allow is a
    # verdict that exits, and every deny rule after this point -- frozen operands, whole-tree commands,
    # the holdout selector on a later segment -- must have run first. Emitting from inside the loop let
    # `./mill app.test` + newline + `rm engine/test/x.scala` through with the whole text wrapped.
    if [ "$_word" = mill ] && [ -z "$_fb_rewrite" ]; then
      _fb_cmd=${cmd%"$_nl"}
      case "$_fb_cmd" in
        *'|'*|*'>'*|*'&&'*|*';'*|*"$_nl"*|'sh .dsh/engine/hooks/feedback.sh'*) ;;
        *)
          for _arg in "$@"; do
            case "$_arg" in
              *.test|*.test.*|*testOnly*|*testForked*|*testCached*|*.compile|*.fix|*.fixStrict)
                _fb_rewrite="sh .dsh/engine/hooks/feedback.sh -- $_fb_cmd" ;;
            esac
          done ;;
      esac
    fi

    # FROZEN PATHS: the operand-shaped commands. Each of these WRITES the paths it names as
    # operands, and none of them is a write shape the semantic guard's extractor can see -- `rm`
    # writes nothing a redirection would name, `mv`'s destination may be a whole directory, and
    # `git checkout -- <path>`, `git restore`, `truncate`, `patch`, `perl -i`, `find -delete`/`-exec
    # rm` and `git rm`/`git mv` are reflexes that quietly rewrite a file.
    #
    # A command is in this set only when the arguments it names ARE paths (or, for `perl` and `find`,
    # only in the writing form -- `-i`, `-delete`, `-exec`): `git checkout <branch>` names a ref, a
    # `git diff` reads, and `perl -pe` without `-i` reads, so none of those is asked.
    #
    # TWO scopes, because the commands differ in which operand they write:
    #   * `all` -- every operand is a path the command writes (`rm <a> <b>`, `mv <frozen> /tmp/y` and
    #     `mv /tmp/y <frozen>` alike, `truncate`, `patch`, `perl -i`, a `find` root, a `git`
    #     pathspec);
    #   * `last` -- only the LAST operand is written, and for `ln` the others are read: `ln -s
    #     <frozen> /tmp/link` creates the link at `/tmp/link` and only READS the frozen target, so
    #     asking every operand would refuse a read. `ln -s /tmp/x <frozen>` and `ln -s /tmp/x
    #     <frozen-dir>/` still deny (the link name is the last operand).
    #
    # `git` is read through `git_subcommand`, so a global option before the subcommand (`git -c
    # core.pager=cat checkout -- <frozen>`, `git -C /tmp checkout -- <frozen>`) does not hide it; an
    # option form that helper does not know is a documented blind spot.
    #
    # A RELATIVE operand is resolved a second time against the directory a `cd`/`pushd` earlier on
    # the line entered (`dsh_bash_action_paths` + `dsh_bash_cd_base`): `cd engine/details && rm -rf
    # src` deletes `engine/details/src`, which the root-relative spelling of `src` does not name. A
    # literal base is resolved exactly; a base this layer cannot know (a variable, `cd ..`, `cd -`)
    # makes a relative operand UNDECIDED, and undecided is denied rather than guessed.
    _fz_kind=
    _fz_scope=all
    _fz_sub=''
    _fz_sub2=''
    if [ "$_word" = git ]; then
      git_scan "$@"
      _fz_sub=$_gs_sub
      _fz_sub2=$_gs_next
    fi
    case "$_word" in
      rm|mv|truncate|patch) _fz_kind=operand ;;
      ln) _fz_kind=operand; _fz_scope=last ;;
      git) case "$_fz_sub" in checkout|restore|rm|mv|apply) _fz_kind=operand ;; esac ;;
      perl) for _arg in "$@"; do case "$_arg" in -i*) _fz_kind=operand ;; esac; done ;;
      find) for _arg in "$@"; do case "$_arg" in -delete|-exec) _fz_kind=operand ;; esac; done ;;
    esac
    if [ -n "$_fz_kind" ]; then
      _fz_last=''
      if [ "$_fz_scope" = last ]; then
        for _arg in "$@"; do
          case "$_arg" in -*) continue ;; esac
          _fz_last=$_arg
        done
      fi
      # For `git`, everything up to and including the subcommand is not an operand -- the global
      # options and their values included, which is what lets `git -c k=v checkout -- <path>` be
      # decided on `<path>` alone.
      _fz_to_sub=0
      [ "$_word" = git ] && _fz_to_sub=1
      _fz_seen_sub=0
      for _arg in "$@"; do
        if [ "$_fz_to_sub" = 1 ] && [ "$_fz_seen_sub" = 0 ]; then
          [ "$_arg" = "$_fz_sub" ] && _fz_seen_sub=1
          continue
        fi
        case "$_arg" in
          -*) continue ;;
        esac
        if [ "$_fz_scope" = last ] && [ "$_arg" != "$_fz_last" ]; then continue; fi
        if _frozen_reason=$(dsh_frozen_reason "$_arg"); then
          deny_frozen_operand "$_arg" "$_frozen_reason"
        fi
        case "$_arg" in
          /*|'~'|'~'/*) continue ;;
        esac
        if [ "$_fz_base_state" = 0 ]; then
          if _frozen_reason=$(dsh_frozen_reason "$_fz_base/$_arg"); then
            deny_frozen_operand "$_fz_base/$_arg" "$_frozen_reason"
          fi
        elif [ "$_fz_base_state" = 2 ]; then
          deny_undecided_operand "$_arg"
        fi
      done
    fi

    # WHOLE-TREE commands. These rewrite the working tree (or a whole directory) rather than the
    # paths they name, so an operand check cannot see them: `git checkout -- .` and `git restore .`
    # discard EVERY modified file, `git clean -fd` deletes the untracked ones, `git stash` (push)
    # and `git reset --hard` rewrite what is there. In this repository that means the human's
    # in-flight files, which a freeze exists to protect -- so when at least one frozen path is
    # configured, they are refused with a message that says so and names the way out. With NO frozen
    # path configured the rule never fires: this layer has nothing to protect there, and a harness
    # that blocked these commands unconditionally would be a policy, not a freeze.
    #
    # `git stash list`/`show` and every dry run (`-n`, `--dry-run`) rewrite nothing and stay allowed,
    # as do the reading commands (`git status`, `git diff`, `git log`).
    if [ "$_word" = git ]; then
      _fz_whole=0
      case "$_fz_sub" in
        clean) _fz_whole=1 ;;
        reset) case " $* " in *" --hard "*) _fz_whole=1 ;; esac ;;
        stash)
          case "$_fz_sub2" in ''|push|pop|save|apply|drop|clear) _fz_whole=1 ;; esac ;;
        checkout|restore)
          for _arg in "$@"; do
            case "$_arg" in .|./|:/) _fz_whole=1 ;; esac
          done
          # `--staged` alone touches the index, not the working tree.
          case " $* " in *" --staged "*)
            case " $* " in *" --worktree "*) ;; *) _fz_whole=0 ;; esac ;;
          esac ;;
      esac
      for _arg in "$@"; do
        # A dry run rewrites nothing: `-n`, a BUNDLED short flag that carries the `n` (`git clean
        # -nd`), or `--dry-run`. The two spellings are decided separately and narrowly, because a
        # bracket class followed by `*` does not backtrack in either shell (`-[a-zA-Z]*n*` matches
        # neither `-n` nor `-nd`), and because a long option carrying an `n` anywhere
        # (`--include-untracked`, `--no-pager`) must NOT be read as a dry run.
        case "$_arg" in
          --*) case "$_arg" in --dry-run) _fz_whole=0 ;; esac ;;
          -n*|-*n*) _fz_whole=0 ;;
        esac
      done
      if [ "$_fz_whole" = 1 ] && [ -n "$(dsh_frozen_paths "$(gate_root)" 2>/dev/null)" ]; then
        deny_whole_tree "$_fz_sub"
      fi
    fi

    # Recursive deletion outside the repository: a recursive flag is present and an argument is
    # absolute or `~`-rooted and not under the gate root. The tilde is quoted in the pattern —
    # an unquoted `~` in a case pattern is tilde-expanded before the match, so `~/*` there
    # would mean `$HOME/*` and `~/scratch` would slip through.
    if [ "$_word" = rm ]; then
      _recursive=0
      for _arg in "$@"; do
        case "$_arg" in
          --recursive) _recursive=1 ;;
          --*) ;;                                      # another long option is not recursion
          -*) case "$_arg" in *[rR]*) _recursive=1 ;; esac ;;
        esac
      done
      if [ "$_recursive" = 1 ]; then
        for _arg in "$@"; do
          case "$_arg" in
            /*|"~"|"~"/*)
              case "$_arg" in
                "$(gate_root)"|"$(gate_root)"/*) ;;
                *) deny "BLOCKED by tool-policy: recursive deletion outside the repository ($_arg).
Delete only under $(gate_root)." ;;
              esac ;;
          esac
        done
      fi
    fi
  done
done
IFS=$_ifs
case "$_dash" in *f*) ;; *) set +f ;; esac

# No rule denied. If the loop decided a feedback rewrite, it is emitted now -- the allow-with-
# updatedInput verdict is the LAST word, never a shortcut past a deny rule that had not yet run.
if [ -n "$_fb_rewrite" ]; then
  dsh_allow_updated_command "$_fb_rewrite" \
    "DSH feedback: test and diagnostic output is shaped by .dsh/engine/hooks/feedback.sh (DIAGNOSTIC/INSTRUCTION lines); the raw log is under .dsh/.state/feedback/"
fi
exit 0
