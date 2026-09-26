#!/bin/sh
# Test double that denies what the in-repo fallback allows: a Mill run names no Scala source,
# so only the delegation path can produce this denial -- and only its own phrasing can.
cat >/dev/null
echo "BLOCKED by ScalaSemantic guard: this call was refused by the generated guard under test." >&2
exit 2
