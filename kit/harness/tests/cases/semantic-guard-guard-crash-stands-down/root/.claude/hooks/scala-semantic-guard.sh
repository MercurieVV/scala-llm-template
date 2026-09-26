#!/bin/sh
# Test double for a generated guard that crashes instead of deciding: exit 3 is neither an
# allow (0) nor a deny (2), and its complaint on stderr is not a verdict.
payload=$(cat)
echo "ScalaSemantic guard crash: cannot read the semanticdb index" >&2
exit 3
