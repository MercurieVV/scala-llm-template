#!/bin/sh
# Vendor this engine into <project>/.dsh/engine/ and seed the project's gate state (spec 2026-09-26 §2).
#   sh kit/harness/install.sh <project>
# The engine is replaced wholesale (built beside the live copy, then renamed in); project state is seeded
# only where absent and never overwritten. One line per file: seeded | kept | replaced.
# Exit 0 installed; 1 usage or not a directory; 2 not a git repository; 3 no sha256 tool; 4 copy failed;
# 5 not run from a template checkout (a vendored .dsh/engine/install.sh has no seed/ and would re-stamp
# an engine edited in place as `ok`, so it refuses before any write).
set -u
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$src/lib.sh"
[ "$#" -eq 1 ] || { printf 'usage: sh %s <project>\n' "$0" >&2; exit 1; }
dst=$(CDPATH= cd -- "$1" 2>/dev/null && pwd) || { printf 'install: %s is not a directory\n' "$1" >&2; exit 1; }
git -C "$dst" rev-parse --show-toplevel >/dev/null 2>&1 || { printf 'install: %s is not a git repository\n' "$dst" >&2; exit 2; }
dsh_has_hasher || { printf 'install: no sha256 tool (shasum or sha256sum) -- the stamp cannot be written\n' >&2; exit 3; }

tpl=$(git -C "$src" rev-parse --show-toplevel 2>/dev/null) || tpl=""
sha=unknown; dirty=0
if [ -n "$tpl" ]; then
  sha=$(git -C "$tpl" rev-parse HEAD 2>/dev/null) || sha=unknown
  [ -n "$(git -C "$tpl" status --porcelain -- "$src" 2>/dev/null)" ] && dirty=1
fi

# Only scala-llm-template's own kit/harness may install: it carries seed/, and it is <toplevel>/kit/harness.
tplh=""
[ -n "$tpl" ] && tplh=$(CDPATH= cd -P -- "$tpl/kit/harness" 2>/dev/null && pwd)
srcp=$(CDPATH= cd -P -- "$src" && pwd)
if [ ! -d "$src/seed" ] || [ -z "$tplh" ] || [ "$tplh" != "$srcp" ]; then
  printf "install: %s is not scala-llm-template's kit/harness (a vendored engine cannot install itself) -- run install.sh from a scala-llm-template checkout\n" "$src" >&2
  exit 5
fi

mkdir -p "$dst/.dsh" || exit 4
new="$dst/.dsh/.engine.new.$$"; old="$dst/.dsh/.engine.old.$$"
trap 'rm -rf "$new" "$old"' EXIT INT TERM
fail() { printf 'install: %s -- the live .dsh/engine is untouched\n' "$1" >&2; exit 4; }
mkdir "$new" || fail "cannot create $new"
cp -R "$src/." "$new/" || fail "copy into $new failed"
[ -n "${DSH_INSTALL_FAIL_COPY:-}" ] && fail "copy failed (DSH_INSTALL_FAIL_COPY test seam)"
dsh_engine_template_only | while IFS= read -r rel; do rm -rf "${new:?}/$rel"; done
rm -f "$new/STAMP"
find "$new" -name .DS_Store -type f -exec rm -f {} + 2>/dev/null
printf 'template=%s\ndirty=%s\ntree=%s\n' "$sha" "$dirty" "$(dsh_engine_tree_hash "$new")" > "$new/STAMP" || fail "cannot write STAMP"

if [ -d "$dst/.dsh/engine" ]; then
  mv "$dst/.dsh/engine" "$old" || fail "cannot move the old engine aside"
  if ! mv "$new" "$dst/.dsh/engine"; then mv "$old" "$dst/.dsh/engine"; fail "cannot move the new engine in"; fi
  printf 'replaced .dsh/engine (template %s%s)\n' "$sha" "$([ "$dirty" = 1 ] && echo ', dirty')"
else
  mv "$new" "$dst/.dsh/engine" || fail "cannot move the new engine in"
  printf 'seeded   .dsh/engine (template %s%s)\n' "$sha" "$([ "$dirty" = 1 ] && echo ', dirty')"
fi

for rel in contract frozen-paths hooks.json cc-settings.json policy/allowed-types.tsv policy/memorisation.tsv instructions/local.tsv instructions/scalac-kinds.tsv; do
  if [ -e "$dst/.dsh/$rel" ]; then
    printf 'kept     .dsh/%s\n' "$rel"
  else
    mkdir -p "$(dirname "$dst/.dsh/$rel")" && cp "$src/seed/$rel" "$dst/.dsh/$rel" || { printf 'install: cannot seed .dsh/%s\n' "$rel" >&2; exit 4; }
    printf 'seeded   .dsh/%s\n' "$rel"
  fi
done
exit 0
