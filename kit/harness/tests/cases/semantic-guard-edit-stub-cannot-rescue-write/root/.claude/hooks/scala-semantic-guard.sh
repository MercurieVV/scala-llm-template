#!/bin/sh
# Test double for a generated guard installed WITHOUT --strict-edits: it allows everything,
# a write of a .scala source included. A write must never reach it -- this case can only
# pass while the write decision stays in-repo (F34).
cat >/dev/null
echo "ScalaSemantic guard: allowed"
exit 0
