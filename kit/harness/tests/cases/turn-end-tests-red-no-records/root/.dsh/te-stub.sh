#!/bin/sh
# A green listing, then the runner dies (Mill fails after the tests; a parse gap): no failure record,
# exit 1. The turn must still block -- "no records" is not "only drafts failed".
cat <<'T'
com.x.A
+ ok 1ms
Total 1, Failed 0, Passed 1, Ignored 0, Cancelled 0
T
exit 1
