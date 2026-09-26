#!/bin/sh
# The ONE sanctioned writer of .dsh/instructions/purrism.tsv (spec 2026-09-20 diagnostic→instruction
# §2): extract purrism/findings.tsv from the scala-purrism-scalafix jar for the version
# buildKit/Layer.mill declares, check the jar's `# purrism <version>` header against that version, and
# replace the table atomically. Human-run, after a purrism bump; check-harness rule 2 says when.
#   sh .dsh/instructions-sync.sh          DSH_PURRISM_JAR=<path> overrides the jar lookup (tests).
# Exit 0 written; 1 jar not found; 2 header/version mismatch (table untouched); 3 not a table.
set -u
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
root=$(gate_root)
ver=$(dsh_purrism_declared_version "$root") || { printf 'instructions-sync: no scala-purrism-scalafix_3:<version> literal in buildKit/Layer.mill\n' >&2; exit 1; }
jar=${DSH_PURRISM_JAR:-}
if [ -z "$jar" ]; then
  cand="$HOME/.ivy2/local/io.github.mercurievv/scala-purrism-scalafix_3/$ver/jars/scala-purrism-scalafix_3.jar"
  if [ -f "$cand" ]; then jar=$cand; else
    for base in "${COURSIER_CACHE:-$HOME/Library/Caches/Coursier/v1}" "$HOME/.cache/coursier"; do
      [ -d "$base" ] || continue
      jar=$(find "$base" -name "scala-purrism-scalafix_3-$ver.jar" -print 2>/dev/null | head -1)
      [ -n "$jar" ] && break
    done
  fi
fi
[ -n "$jar" ] && [ -f "$jar" ] || { printf 'instructions-sync: no jar for scala-purrism-scalafix_3 %s (ivy2 local, coursier cache); publishLocal or resolve it, or set DSH_PURRISM_JAR\n' "$ver" >&2; exit 1; }
# The temp file lives next to the target, so the `mv -f` below is a same-filesystem rename (atomic),
# never a cross-device copy.
mkdir -p "$root/.dsh/instructions"
tmp=$(mktemp "$root/.dsh/instructions/.purrism.XXXXXX") || exit 3
if ! unzip -p "$jar" purrism/findings.tsv > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
  rm -f "$tmp"; printf 'instructions-sync: %s holds no purrism/findings.tsv\n' "$jar" >&2; exit 3
fi
head=$(head -1 "$tmp")
case "$head" in
  "# purrism $ver") ;;
  "# purrism "*)
    jv=${head#"# purrism "}; rm -f "$tmp"
    printf 'instructions-sync: version mismatch — jar says %s, buildKit/Layer.mill says %s; table left untouched\n' "$jv" "$ver" >&2; exit 2 ;;
  *) rm -f "$tmp"; printf 'instructions-sync: first line is not `# purrism <version>`: %s\n' "$head" >&2; exit 3 ;;
esac
bad=$(awk -F'\t' 'NR > 1 && NF && NF != 6 { n++ } END { print n + 0 }' "$tmp")
[ "$bad" = 0 ] || { rm -f "$tmp"; printf 'instructions-sync: %s row(s) are not six TAB fields\n' "$bad" >&2; exit 3; }
n=$(awk 'NR > 1 && NF' "$tmp" | wc -l | tr -d ' ')
mv -f "$tmp" "$root/.dsh/instructions/purrism.tsv"
printf 'instructions-sync: wrote .dsh/instructions/purrism.tsv (purrism %s, %s finding(s)) from %s\n' "$ver" "$n" "$jar"
