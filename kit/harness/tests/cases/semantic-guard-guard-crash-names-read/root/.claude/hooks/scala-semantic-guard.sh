#!/bin/sh
# Test double for a generated guard that crashes instead of deciding: exit 3 is neither an
# allow (0) nor a deny (2). This case pins the OPERATION named in the stand-down line (F35):
# a read must not be reported as "the call".
payload=$(cat)
echo "ScalaSemantic guard crash: cannot read the semanticdb index" >&2
exit 3
