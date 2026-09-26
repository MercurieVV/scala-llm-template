#!/bin/sh
# The simulated purrism rewrite: run by the Mill stub for core.fixRanges, cwd the scratch root.
sed -i.bak 's/o.get/o.getOrElse(0)/' core/src/T.scala && rm -f core/src/T.scala.bak
