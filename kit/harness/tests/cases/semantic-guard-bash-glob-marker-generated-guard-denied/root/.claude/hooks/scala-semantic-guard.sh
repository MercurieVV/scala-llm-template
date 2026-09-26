#!/bin/sh
# Test double for the ScalaSemantic-generated guard: denies anything that is not a .mill/.md path.
payload=$(cat)
case "$payload" in
  *".scala"*) echo "BLOCKED by ScalaSemantic guard: text tools are not allowed on .scala sources here." >&2; exit 2 ;;
  *) exit 0 ;;
esac
