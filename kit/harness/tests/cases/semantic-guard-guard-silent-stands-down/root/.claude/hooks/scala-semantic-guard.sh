#!/bin/sh
# Test double for a generated guard that fails silently: exit 1 with nothing on either stream,
# which a fail-closed bridge would otherwise report as a denial with no reason at all.
cat >/dev/null
exit 1
