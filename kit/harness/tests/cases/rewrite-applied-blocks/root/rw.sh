#!/bin/sh
# The simulated purrism rewrite, run by the Mill stub with Mill's own arguments (cwd the scratch root):
# each module rewrites only its own file, and keeps the ranges file it was handed for post_gate to read.
while [ $# -gt 0 ]; do
  case "$1" in
    --rangesFile) shift; ranges=$1 ;;
    *.fixRanges) mod=${1%.fixRanges} ;;
  esac
  shift
done
cp "$ranges" "ranges-$mod.tsv"
case "$mod" in
  core) f=core/src/T.scala ;;
  app) f=app/src/A.scala ;;
esac
sed -i.bak 's/o.get/o.getOrElse(0)/' "$f" && rm -f "$f.bak"
