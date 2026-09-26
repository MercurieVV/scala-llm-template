#!/bin/sh
# Diff-scoped deterministic verification (spec 2026-09-24 §2-§3): before a turn may end, every name
# the turn's changed LINES introduce must resolve, every resolved symbol must be one the module's
# policy permits, and every dependency coordinate an added build line introduces must resolve.
#
# Run by the turn-end gate BEFORE the per-module compile chain (it is cheap, and a failure here
# blocks with a precise diff-scoped message instead of paying for a compile that says the same thing
# less clearly), and again from tool-policy before `git commit` / `./mill prePush` with `--staged`,
# where every FINDING is blocking: a turn is a work-in-progress checkpoint, a commit is what the
# repository keeps.
#
# A FINDING and a DEGRADATION are different things and the `--staged` fold treats them differently.
# A finding is something the gate found WRONG — an unresolved name, a policy violation, a coordinate
# that does not resolve, an unresolved name repeated in prose. A degradation is "I could not check":
# no `timeout` on PATH, no launcher, no `cs`, a file the tool did not answer for, a turn with no
# Scala file to hang the prose check on, more changed Scala files than one call may carry. Findings promote to blocks at
# the commit boundary; degradations never do. Promoting "I could not check" into "you may not commit"
# hands the agent a denial no edit of its own can clear — on a machine with no `timeout` that is
# EVERY commit — which is worse than the silent pass this gate exists to remove.
#
# The split of responsibility is the whole design. THIS FILE owns git, the module and build context,
# the project policy, the dependency check and the verdict. `resolve_references` owns Scala semantic
# facts and nothing else: no policy argument crosses that boundary, and the tool never sees a diff.
#
# Never a silent pass. Every path that could not check something emits a NOTE naming what it could
# not check and lets the turn continue. Exit 0 allows, exit 2 blocks. POSIX sh only.
set -u
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/lib.sh"

# --staged            check the INDEX (`git commit`, `./mill prePush`), where findings block.
# --staged-worktree   the same boundary, but read the TRACKED WORKING TREE instead of the index:
#                     `git commit -a` and `git commit <path>` stage AFTER this hook has run, so the
#                     index the gate would read does not hold the change being committed — measured,
#                     the gate read an empty index, exited 0 in silence, and the commit went through
#                     unchecked. `git diff HEAD` covers what is staged AND what such a commit is
#                     about to stage. Untracked files stay out: neither form commits them.
staged=0
worktree=0
for _vd_arg in "$@"; do
  case "$_vd_arg" in
    --staged) staged=1 ;;
    --staged-worktree) staged=1; worktree=1 ;;
  esac
done

root=$(gate_root)
cd "$root" 2>/dev/null || { printf 'verify-diff: the root %s cannot be entered — nothing was checked.\n' "$root"; exit 0; }

tmpd=$(mktemp -d 2>/dev/null) || tmpd=${TMPDIR:-/tmp}/dsh-verify.$$
mkdir -p "$tmpd" 2>/dev/null
trap 'rm -rf "$tmpd" 2>/dev/null' 0

max_lines=15
report=''
notes=''
dnotes=''
blocked=0
noted=0

# A DEGRADATION note: "this could not be checked", never "this is wrong". It is printed exactly like
# a finding note and read exactly like one by a human — the difference is only that the `--staged`
# fold at the bottom never promotes it to a block, because nothing the agent can stage would clear
# it. `section note` stays the emitter for FINDINGS that merely note at turn-end.
dnote() { # <title> <body>
  _dn_body=$2
  [ -n "$_dn_body" ] || _dn_body='(the check printed nothing)'
  dnotes="$dnotes
--- $1 ---
$(bound_lines "$_dn_body" "$max_lines")"
}

# --- the change set ------------------------------------------------------------------------------
# Turn-end compares against the baseline the gate already computes; --staged reads the index. A git
# that cannot be read is a NOTE, never a block: the ranges would be wrong, and a wrong range reports
# old breakage as new.
base=${DSH_VERIFY_BASELINE:-HEAD}
if [ "$staged" = 1 ] && [ "$worktree" = 1 ]; then
  git diff -U0 HEAD > "$tmpd/diff" 2>"$tmpd/gierr"
elif [ "$staged" = 1 ]; then
  git diff --cached -U0 > "$tmpd/diff" 2>"$tmpd/gierr"
else
  git diff -U0 "$base" > "$tmpd/diff" 2>"$tmpd/gierr"
fi
if [ $? != 0 ]; then
  printf -- '--- diff-scoped verification (not run) ---\nverify-diff: git could not be read (%s), so the changed line ranges are unknown and nothing was checked.\n' \
    "$(bound_lines "$(cat "$tmpd/gierr" 2>/dev/null)" 3)"
  exit 0
fi
# Untracked new files count whole: they are in no diff, so their whole extent is the range.
if [ "$staged" = 0 ]; then
  # A brand-new file is in no diff — `git diff` never mentions it — so it has to be walked
  # separately or it is invisible to every check below it, including the prose NOTE: a turn whose
  # only change is a freshly created .md would otherwise produce nothing at all, which is exactly
  # the silent pass this gate exists to rule out. Scala files (checked) and non-build, non-Scala
  # files (prose) both get their whole extent as the range; a build file is excluded here the same
  # way the prose filter below excludes a TRACKED one — an untracked build file is the dependency
  # check's business, and that check reads `git diff`, not this walk.
  git ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r u; do
    [ -n "$u" ] || continue
    case "$u" in
      *.mill|*.sbt) continue ;;
    esac
    [ -f "$u" ] || continue
    _n=$(wc -l < "$u" 2>/dev/null | tr -d ' ')
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    [ "$_n" -gt 0 ] && printf '%s\t0\t%s\n' "$u" "$_n"
  done > "$tmpd/untracked"
else
  : > "$tmpd/untracked"
fi

dsh_diff_ranges "$tmpd/diff" "$tmpd/ranges"
cat "$tmpd/untracked" >> "$tmpd/ranges" 2>/dev/null

# Three ways: Scala sources to the semantic check, build files to the dependency check, everything
# else (.md, comment-only diffs) to the prose check — which notes at turn-end and blocks staged.
awk -F'\t' '$1 ~ /\.(scala|sc)$/' "$tmpd/ranges" > "$tmpd/scala"
awk -F'\t' '$1 !~ /\.(scala|sc)$/ && $1 !~ /\.(mill|sbt)$/' "$tmpd/ranges" > "$tmpd/prose"

# --- the semantic check --------------------------------------------------------------------------
# The launcher is resolved exactly as .dsh/hooks/health.sh resolves it: override, PATH, profile path.
launcher=${SCALASEMANTIC_MCP_LAUNCHER:-}
if [ -z "$launcher" ]; then
  launcher=$(command -v scalasemantic-mcp 2>/dev/null) || launcher=""
  if [ -n "$launcher" ] && [ ! -f "$launcher" ]; then
    launcher=/Users/viktorskalinins/.local/bin/scalasemantic-mcp
  fi
fi
[ -n "$launcher" ] || launcher=/Users/viktorskalinins/.local/bin/scalasemantic-mcp

semantic_note=''
prose_note=''
if [ ! -s "$tmpd/scala" ]; then
  # Nothing changed in Scala: the semantic check has nothing to say, and — since it is the ONLY
  # source of names for the prose check below — nothing was checked in prose either. The tool
  # answers about Scala files it is asked about and nothing else, so a turn that touches only a
  # .md (or other non-build) file has no reachable way to be checked; saying so is what "never a
  # silent pass" demands, even though this NOTE is never blocking.
  if [ -s "$tmpd/prose" ]; then
    prose_note="this turn changed no Scala file, so the names in $(cut -f1 "$tmpd/prose" | sort -u | tr '\n' ' ' | sed 's/ $//') were not checked — the semantic tool only answers about Scala files."
  fi
elif [ ! -x "$launcher" ]; then
  semantic_note="the semantic check did not run: no scalasemantic-mcp launcher at $launcher"
else
  # {"files":[{"uri":"<path>","ranges":[[s,e],...]}]} — built by awk so a path is never hand-quoted.
  # jesc backslash-then-quote escapes the path before it goes inside a JSON string: a path
  # containing `"` or `\` (rare, but git allows both) would otherwise close the string early or
  # corrupt the next byte, so the tool sees invalid JSON and answers nothing for the whole request.
  awk -F'\t' '
    function jesc(s) {
      gsub(/\\/, "\\\\", s)
      gsub(/"/, "\\\"", s)
      return s
    }
    BEGIN { printf "{\"files\":[" ; first = 1 }
    {
      if ($1 != cur) {
        if (!first) printf "]}"
        printf "%s{\"uri\":\"%s\",\"ranges\":[", (first ? "" : ","), jesc($1)
        cur = $1; first = 0; rfirst = 1
      }
      printf "%s[%d,%d]", (rfirst ? "" : ","), $2, $3
      rfirst = 0
    }
    END { if (!first) printf "]}" ; printf "]}" }
  ' "$tmpd/scala" > "$tmpd/req.json"

  # Spec §3: more than 50 changed Scala files -> check the largest changes first and NOTE the cut.
  # "Largest" is the number of changed lines, which is what the ranges already measure.
  nfiles=$(cut -f1 "$tmpd/scala" | sort -u | wc -l | tr -d ' ')
  if [ "$nfiles" -gt 50 ]; then
    awk -F'\t' '{ w[$1] += $3 - $2 } END { for (f in w) printf "%d\t%s\n", w[f], f }' "$tmpd/scala" \
      | sort -rn | head -50 | cut -f2 | sort > "$tmpd/keep"
    awk -F'\t' 'NR == FNR { keep[$0] = 1; next } ($1 in keep)' "$tmpd/keep" "$tmpd/scala" > "$tmpd/scala.cut"
    mv "$tmpd/scala.cut" "$tmpd/scala"
    # A DEGRADATION, not a finding: its own words are "the rest were NOT CHECKED", and nothing the
    # agent edits clears it — only abandoning the shape of the commit would, and a 51-file mechanical
    # rename is a legitimate commit. So it must not promote at `--staged`.
    dnote "diff-scoped verification (truncated)" "this turn changed $nfiles Scala files; the 50 with the most changed lines were checked and the rest were not."
  fi

  # No classpath is passed: the server DISCOVERS it from `.scala-semantic/classpath-<tool>.json` under
  # the workspace root (ScalaSemanticMCP docs/getting-started/integration.md). Without that metadata
  # the one-shot call exits 1 for the whole request, which the branch below notes with its reason.
  # Spec §3 caps the call at 30 s. `timeout` is not POSIX and is absent on stock macOS, so it is used
  # when it is there and the call runs uncapped (with a note saying so) when it is not — an uncapped
  # call that hangs is worse than a slow turn, but inventing a background-kill in POSIX sh is worse
  # than both.
  if command -v timeout >/dev/null 2>&1; then
    cap="timeout 30"
  else
    cap=""
    semantic_note="the 30 s cap on the semantic call was not applied: no \`timeout\` on PATH"
  fi
  timeout_rc=0
  $cap "$launcher" call resolve_references "$(cat "$tmpd/req.json")" "$root" > "$tmpd/resp.json" 2>"$tmpd/callerr" || timeout_rc=$?
  if [ "$timeout_rc" = 124 ]; then
    semantic_note="the semantic check did not run: scalasemantic-mcp call exceeded the 30 s cap"
  elif [ "$timeout_rc" != 0 ]; then
    # The launcher's reason sits BENEATH the JVM's own `WARNING: ... sun.misc.Unsafe` lines, so
    # bounding raw stderr quoted the deprecation warnings as the reason and hid the real one. Drop
    # them first; if nothing else is left, say so rather than quoting an empty reason.
    call_reason=$(grep -v '^WARNING:' "$tmpd/callerr" 2>/dev/null)
    [ -n "$call_reason" ] || call_reason='(no reason printed beyond JVM warnings)'
    semantic_note="the semantic check did not run: scalasemantic-mcp call exited $timeout_rc — $(bound_lines "$call_reason" 3)"
  else
    # One TAB row per reference: uri, line, character, name, resolved, symbol, origin, suggestions.
    # `null` is upickle's spelling of an absent Option, so every optional read filters on TYPE.
    if command -v jq >/dev/null 2>&1; then
      jq -r '.files[]? | .uri as $u |
        if (.error // null) != null and (.references | not) then
          [$u, "-", "-", "-", "ERROR", (.error), "-", "-"] | @tsv
        else
          (.references // [])[] |
          [$u, (.line|tostring), (.character|tostring), .name,
           (if .resolved then "true" else "false" end),
           (.symbol // "-"), (.origin // "-"),
           ((.suggestions // []) | join(" "))] | @tsv
        end' "$tmpd/resp.json" > "$tmpd/rows" 2>/dev/null || : > "$tmpd/rows"
      # The ANSWERED set is one line per `files[].uri` the response carried, independently of how
      # many reference rows that file produced. `{"files":[]}` (no answer) and
      # `{"files":[{"uri":X,"references":[]}]}` (answered, nothing to say — the ordinary answer for a
      # comment-only, format-only or deletion-only change) are different answers and deriving the set
      # from the ROWS conflates them into a false "not checked".
      jq -r '.files[]? | .uri // empty' "$tmpd/resp.json" > "$tmpd/answered" 2>/dev/null || : > "$tmpd/answered"
    elif command -v python3 >/dev/null 2>&1; then
      python3 - "$tmpd/resp.json" "$tmpd/answered" > "$tmpd/rows" 2>/dev/null <<'PY' || : > "$tmpd/rows"
import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
answered = open(sys.argv[2], "w")
for f in d.get("files") or []:
    u = f.get("uri") or "-"
    if f.get("uri"):
        answered.write(f["uri"] + "\n")
    refs = f.get("references")
    if refs is None and f.get("error"):
        print("\t".join([u, "-", "-", "-", "ERROR", str(f.get("error")), "-", "-"]))
        continue
    for r in refs or []:
        sug = r.get("suggestions") or []
        print("\t".join([
            u, str(r.get("line", "-")), str(r.get("character", "-")),
            str(r.get("name", "-")), "true" if r.get("resolved") else "false",
            r.get("symbol") or "-", r.get("origin") or "-", " ".join(sug)]))
answered.close()
PY
    else
      : > "$tmpd/rows"
      : > "$tmpd/answered"
      semantic_note='the semantic check did not run: no jq and no python3 to read the answer'
    fi
  fi
fi

# --- check for files sent but not answered -------------------------------------------------------
# Every file we SENT must come back in the response's `files[]` — with references, with an empty
# `references` list, or with an error. A file absent from `files[]` (empty stdout, `{"files":[]}`, a
# dropped entry) was not checked, and saying so is what "never a silent pass" demands. The set of
# ANSWERED files is the response's own `files[].uri` list, never the reference rows: a file the tool
# answered with `"references": []` — the ordinary answer for a comment-only, format-only or
# deletion-only change — produces no row at all and would otherwise read as unanswered.
# ScalaSemanticMCP echoes the uri VERBATIM (`McpTools` passes the request's `uri.value` into every
# output shape and into `FileReferences`; `DocumentUri.from` only validates relative-and-no-`..`, it
# does not rewrite), so the join is a plain string comparison against what we sent.
# Files whose entry carries an ERROR are already named by the error path below; they are answered, so
# they are not listed here and there is no double report.
# Skip only when a high-level launcher/parse failure already said the check did not run; a timeout
# WARNING is not that (the tool still ran and the response is readable).
unchecked_check_skip=0
case "${semantic_note:-}" in
  "the semantic check did not run"*) unchecked_check_skip=1 ;;
esac
if [ "$unchecked_check_skip" = 0 ] && [ -s "$tmpd/scala" ]; then
  cut -f1 "$tmpd/scala" | sort -u > "$tmpd/sent"
  sort -u "$tmpd/answered" 2>/dev/null > "$tmpd/answered.u" || : > "$tmpd/answered.u"
  # A whole line is the key, so a path containing a space, a glob character or any other shell
  # metacharacter joins as itself — no word splitting, no globbing. The file is told apart by
  # FILENAME rather than by `NR == FNR`, which reads the SECOND file as the first when the first is
  # empty — and an empty `answered` (the tool answered nothing at all) is exactly the case this note
  # exists for.
  awk -v af="$tmpd/answered.u" 'FILENAME == af { a[$0] = 1; next } !($0 in a)' \
    "$tmpd/answered.u" "$tmpd/sent" > "$tmpd/unchecked"
  if [ -s "$tmpd/unchecked" ]; then
    dnote "names in Scala files (not checked)" "the semantic check could not verify the names introduced in these files:
$(sed 's/^/  /' "$tmpd/unchecked")"
  fi
fi

# --- verdicts from the rows ------------------------------------------------------------------------
tab=$(printf '\t')
unresolved=''
violations=''
if [ -s "$tmpd/rows" ]; then
  while IFS="$tab" read -r r_uri r_line r_col r_name r_res r_sym r_org r_sug; do
    [ -n "$r_uri" ] || continue
    if [ "$r_res" = ERROR ]; then
      semantic_note="the semantic check did not run for $r_uri: $r_sym"
      continue
    fi
    if [ "$r_res" = false ]; then
      # A row's uri is a CODE finding — and so eligible to block — only when it names an actual
      # Scala source; `resolve_references` never answers about anything else, but the launcher is a
      # process boundary and a malformed or stubbed answer must not be trusted past what the tool
      # can actually claim. A non-Scala uri still feeds the prose check below (its `name` still
      # lands in badnames), it just never blocks on its own.
      case "$r_uri" in
        *.scala|*.sc)
          if [ -n "$r_sug" ]; then
            unresolved="$unresolved
  $r_uri:$r_line $r_name did not resolve — did you mean: $r_sug"
          else
            unresolved="$unresolved
  $r_uri:$r_line $r_name did not resolve (no near-miss in the index)"
          fi
          ;;
      esac
      continue
    fi
    # Non-Scala uris carry no symbol for the policy check either.
    case "$r_uri" in
      *.scala|*.sc) : ;;
      *) continue ;;
    esac
    # stdlib is always allowed, and the tool's own `origin` is what says so — no policy crossed the
    # boundary to get this answer.
    [ "$r_org" = stdlib ] && continue
    moddir=$(awk -F"$tab" -v p="$r_uri" '$1 != "" && index(p, $1 "/") == 1 { if (length($1) > length(best)) best = $1 } END { print best }' \
      "$(state_dir)/modules.tsv" 2>/dev/null)
    [ -n "$moddir" ] || continue
    if ! why=$(dsh_policy_allows "$r_sym" "$moddir" "$root"); then
      violations="$violations
  $r_uri:$r_line $r_sym is not allowed in $moddir — $why"
    fi
  done < "$tmpd/rows"
fi

if [ -n "$unresolved" ]; then
  blocked=$((blocked + 1))
  section blocking "names this turn introduced that do not resolve" "$unresolved"
fi
if [ -n "$violations" ]; then
  # Spec §3: with no SemanticDB index yet, the PC still answers for the buffer but `origin: project`
  # is unknowable, so a policy finding cannot be trusted — it is downgraded to a NOTE that says so.
  # `dsh_semanticdb_files` is lib.sh's own index probe, the one health.sh uses.
  if [ -n "$(dsh_semanticdb_files "$root" 2>/dev/null | head -1)" ]; then
    blocked=$((blocked + 1))
    section blocking "symbols outside the module's allowed prefixes (.dsh/policy/allowed-types.tsv)" "$violations"
  else
    # A degradation, not a finding: the gate is saying it cannot TRUST this answer, and no edit the
    # agent makes would build the missing index, so it must not promote to a block at a commit.
    dnote "symbols outside the module's allowed prefixes — NOT blocking, there is no SemanticDB index yet so a symbol's origin cannot be trusted" "$violations"
  fi
fi

# --- the dependency check ---------------------------------------------------------------------------
coords=$(dsh_diff_coordinates "$tmpd/diff")
if [ -n "$coords" ]; then
  if ! command -v cs >/dev/null 2>&1; then
    dnote "dependency coordinates (not checked)" "no \`cs\` (coursier) on PATH, so these added coordinates were not resolved:
$(printf '%s\n' "$coords" | sed 's/^/  /')"
  else
    bad=''
    for c in $coords; do
      cs resolve "$c" >/dev/null 2>&1 || bad="$bad
  $c does not resolve"
    done
    if [ -n "$bad" ]; then
      blocked=$((blocked + 1))
      section blocking "dependency coordinates that do not resolve" "$bad"
    fi
  fi
fi

# --- memorisation (spec 2026-09-25 §3) ------------------------------------------------------------
# A production construct whose literals are largely the tests' own values has learned the tests, not
# the problem. Production literals are read WHOLE-FILE and kept for the constructs this turn touched,
# so a table grown a few rows per turn is still judged whole. Only VISIBLE tests count: the sealed
# holdout is what the agent cannot see, and so cannot memorise.
#
# Every `literal_tokens` answer is read by `dsh_memo_read` against the files REQUESTED: a row for a
# file nobody asked about is dropped (a production value must never match itself as a "test" value),
# and every requested file must come back with its literals or its error. A file with neither, an
# error, an `omitted` count, an answer that is not JSON, no JSON reader, no module map: each is a
# DEGRADATION note naming what was not read, never a block and never silence. A test set that is
# missing any of its files is not cached, so a gap never outlives the turn that could not fill it.
memo_req() { # <file-list> -> {"files":[{"uri":...}, ...]}, paths JSON-escaped
  awk 'BEGIN { printf "{\"files\":[" }
       { v = $0; gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); printf "%s{\"uri\":\"%s\"}", (NR > 1 ? "," : ""), v }
       END { printf "]}" }' "$1"
}
memo_call() { # <file-list> <answer.json> -> rc; the stderr reason lands in $tmpd/memoerr
  _mc_rc=0
  $cap "$launcher" call literal_tokens "$(memo_req "$1")" "$root" > "$2" 2>"$tmpd/memoerr" || _mc_rc=$?
  return "$_mc_rc"
}
memo_read() { # <answer.json> <file-list> <prefix> <which: test|changed> -> 0 when rows were read
  _mr_rc=0
  dsh_memo_read "$1" "$2" "$3" || _mr_rc=$?
  case "$_mr_rc" in
    0) return 0 ;;
    2) dnote "memorisation (not checked)" "no jq and no python3 to read literal_tokens' answer for the $4 sources" ;;
    *) dnote "memorisation (not checked)" "literal_tokens' answer for the $4 sources is not a readable literal_tokens answer: $(bound_lines "$(cat "$1" 2>/dev/null)" 3)" ;;
  esac
  return 1
}
memo_unread() { # <unread-file> -> one indented `uri: reason` line per file
  awk -F'\t' '{ print "  " $1 ": " $2 }' "$1"
}

cut -f1 "$tmpd/scala" | sort -u | while IFS= read -r mf; do
  [ -n "$mf" ] || continue
  dsh_is_test_path "$mf" "$root" || printf '%s\n' "$mf"
done > "$tmpd/prodfiles"

if [ -s "$tmpd/prodfiles" ] && [ ! -s "$root/.dsh/.state/modules.tsv" ]; then
  # Not "no test sources": with no map NOTHING classifies as a test, so silence here would read as a
  # clean check. The map is gitignored and turn-end builds it only AFTER this script runs, so a fresh
  # clone's first turn lands here.
  dnote "memorisation (not checked)" "the module map (.dsh/.state/modules.tsv) is not built yet, so the test sources could not be identified and no construct was compared with them."
elif [ -s "$tmpd/prodfiles" ] && [ -x "$launcher" ]; then
  awk -F'\t' '$1 != "" { print $1 "/test" }' "$root/.dsh/.state/modules.tsv" 2>/dev/null | sort -u \
    | while IFS= read -r td; do [ -d "$root/$td" ] && (cd "$root" && find "$td" -type f -name '*.scala'); done \
    | sort -u | while IFS= read -r tf; do dsh_is_test_path "$tf" "$root" && printf '%s\n' "$tf"; done \
    > "$tmpd/testfiles"
  if [ -s "$tmpd/testfiles" ]; then
    # The test literal set, cached by the test files' content: an unchanged test tree is not re-read.
    # Only a COMPLETE set is cached: every test file answered, none with an error or an omitted count.
    # Only with a hasher: without one `dsh_file_hash` prints `-` for every file, the key would change
    # only when the LIST of test files does, and an edited test would be judged by its stale literals
    # — an undercount that passes in silence. So with no hasher the set is read fresh every time.
    memo_cache=''
    if dsh_has_hasher; then
      memo_key=$(while IFS= read -r tf; do printf '%s %s\n' "$tf" "$(dsh_file_hash "$root/$tf")"; done < "$tmpd/testfiles" | cksum | cut -d' ' -f1)
      memo_cache="$(state_dir)/memo-testvals.$memo_key"
    fi
    memo_ok=1
    if [ -n "$memo_cache" ] && [ -s "$memo_cache" ]; then
      cp "$memo_cache" "$tmpd/testvals"
    elif memo_call "$tmpd/testfiles" "$tmpd/test.json"; then
      if memo_read "$tmpd/test.json" "$tmpd/testfiles" "$tmpd/test" test; then
        cut -f4 "$tmpd/test.rows" > "$tmpd/testvals"
        if [ -s "$tmpd/test.unread" ]; then
          dnote "test source(s) could not be read for literals" "their literals are missing or incomplete, so an overlap may be undercounted (this partial set is not cached):
$(memo_unread "$tmpd/test.unread")"
        elif [ -n "$memo_cache" ]; then
          cp "$tmpd/testvals" "$memo_cache" 2>/dev/null || :
        fi
      else
        memo_ok=0
      fi
    else
      memo_ok=0
      dnote "memorisation (not checked)" "literal_tokens failed for the test sources: $(bound_lines "$(grep -v '^WARNING:' "$tmpd/memoerr")" 3)"
    fi
    if [ "$memo_ok" = 1 ]; then
      if memo_call "$tmpd/prodfiles" "$tmpd/prod.json"; then
        if memo_read "$tmpd/prod.json" "$tmpd/prodfiles" "$tmpd/prod" changed; then
          if [ -s "$tmpd/prod.unread" ]; then
            dnote "changed source(s) could not be read for literals" "constructs in these files were not judged for memorisation (the whole file on an error or a missing entry, the literals past the cap when partly read):
$(memo_unread "$tmpd/prod.unread")"
          fi
          awk -F'\t' -v OFS='\t' '
            FILENAME == scala { lo[$1, ++c[$1]] = $2; hi[$1, c[$1]] = $3; next }
            { t = 0; for (i = 1; i <= c[$1]; i++) if ($2 >= lo[$1, i] && $2 < hi[$1, i]) { t = 1; break }
              print $1, $5, $3, $4, t }' scala="$tmpd/scala" "$tmpd/scala" "$tmpd/prod.rows" > "$tmpd/prod.tsv"
          memo_hits=$(dsh_memo_judge "$tmpd/prod.tsv" "$tmpd/testvals" "$root" | while IFS="$tab" read -r mp mc mk mn ms; do
            printf '  %s %s: %s of %s literals also appear in the tests — e.g. %s\n' "$mp" "$mc" "$mk" "$mn" "$ms"
          done)
          if [ -n "$memo_hits" ]; then
            blocked=$((blocked + 1))
            section blocking "construct(s) whose literals are largely the tests' own values" "$memo_hits
Exempt a legitimate table with an allow row in .dsh/policy/memorisation.tsv (the human's)."
          fi
        fi
      else
        dnote "memorisation (not checked)" "literal_tokens failed for the changed sources: $(bound_lines "$(grep -v '^WARNING:' "$tmpd/memoerr")" 3)"
      fi
    fi
  fi
elif [ -s "$tmpd/prodfiles" ]; then
  dnote "memorisation (not checked)" "no scalasemantic-mcp launcher at $launcher"
fi

# --- prose (spec 2026-09-24 §2, the NOTE row of the verdict table) -----------------------------------
# A hallucinated API name in a .md file or a comment-only diff misleads a reader, but it never blocks
# a TURN. It is checked by looking for the unresolved NAMES the semantic check already found inside
# the prose lines this turn added — no second tool call, and nothing here parses English. At a commit
# the `--staged` fold below turns it into a block, because a commit is what the repository keeps.
if [ -s "$tmpd/prose" ] && [ -s "$tmpd/rows" ]; then
  prose_hits=''
  awk -F'\t' '$5 == "false" { print $4 }' "$tmpd/rows" | sort -u > "$tmpd/badnames"
  while IFS="$tab" read -r p_path p_start p_end; do
    [ -f "$p_path" ] || continue
    while IFS= read -r p_name; do
      [ -n "$p_name" ] || continue
      if sed -n "$((p_start + 1)),${p_end}p" "$p_path" 2>/dev/null | grep -Fq "$p_name"; then
        prose_hits="$prose_hits
  $p_path names $p_name, which does not resolve anywhere in this project"
      fi
    done < "$tmpd/badnames"
  done < "$tmpd/prose"
  if [ -n "$prose_hits" ]; then
    noted=$((noted + 1))
    section note "names in prose that do not resolve (not blocking)" "$prose_hits"
  fi
fi

if [ -n "$prose_note" ]; then
  dnote "names in prose (not checked)" "$prose_note"
fi

if [ -n "$semantic_note" ]; then
  dnote "diff-scoped verification (partial)" "$semantic_note"
fi

if [ "$staged" = 1 ] && [ "$noted" -gt 0 ]; then
  # Every FINDING blocks at the repository boundary, including the ones that only note at turn-end.
  # The DEGRADATION notes ($dnotes) are deliberately not folded: see the header. They are still
  # printed, so the commit that goes through says what about it was not checked.
  blocked=$((blocked + noted))
  report="$report$notes"
  notes=''
fi
notes="$notes$dnotes"

if [ "$blocked" -gt 0 ]; then
  printf 'diff-scoped verification found %s blocking finding(s):\n%s\n' "$blocked" "$report"
  [ -n "$notes" ] && printf '%s\n' "$notes"
  exit 2
fi
[ -n "$notes" ] && printf '%s\n' "$notes"
exit 0
