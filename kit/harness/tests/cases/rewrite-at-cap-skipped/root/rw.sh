#!/bin/sh
# The simulated purrism rewrite, run by the Mill stub with Mill's own arguments (cwd the scratch root):
# every `.get` in the module's own sources becomes `.getOrElse(0)` — in range or not, so a file the
# gate should have kept away from fixRanges shows the rewrite if it was ever handed over.
for a in "$@"; do case "$a" in *.fixRanges) mod=${a%.fixRanges} ;; esac; done
for f in "$mod"/src/*.scala; do
  [ -f "$f" ] || continue
  sed -i.bak 's/o\.get$/o.getOrElse(0)/' "$f" && rm -f "$f.bak"
done
