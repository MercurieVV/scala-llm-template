#!/bin/sh
# A rewrite of BOTH files that breaks the compile: the stub fails core.compile while any .scala file
# contains BROKEN, so a revert that restored only the first file would leave the second one failing.
for f in core/src/T.scala core/src/U.scala; do
  sed -i.bak 's/o.get/o.BROKEN/' "$f" && rm -f "$f.bak"
done
