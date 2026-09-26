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
# Text, not shell semantics: `bash -c 'sbt …'`, a substitution (`echo $(git push --force)`) and a wrapper's own
# options (`git -c foo=bar push --force`, `sudo -u root sbt …`) are not detected, so this is one layer of four, not a sandbox.
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
    while [ $# -gt 0 ]; do
      case "$1" in
        sudo|env|time|nohup|command|exec|xargs|do|then|else|if|while|until|'{'|'(') shift ;;
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
# the sbt denial below never fired there; `.dsh/tests/vocabulary-test.sh` now sends both spellings
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
        *'|'*|*'>'*|*'&&'*|*';'*|*"$_nl"*|'sh .dsh/hooks/feedback.sh'*) ;;
        *)
          for _arg in "$@"; do
            case "$_arg" in
              *.test|*.test.*|*testOnly*|*testForked*|*testCached*|*.compile|*.fix|*.fixStrict)
                _fb_rewrite="sh .dsh/hooks/feedback.sh -- $_fb_cmd" ;;
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
    "DSH feedback: test and diagnostic output is shaped by .dsh/hooks/feedback.sh (DIAGNOSTIC/INSTRUCTION lines); the raw log is under .dsh/.state/feedback/"
fi
exit 0
