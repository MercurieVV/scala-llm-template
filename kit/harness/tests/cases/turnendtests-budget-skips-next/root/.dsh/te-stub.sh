#!/bin/sh
# Records which module actually ran (the log post_gate reads), then eats most of the tiny
# DSH_STOP_BUDGET=16 this case sets -- only for the first module (app) -- so core's turn finds ten
# seconds or less left and is not started at all.
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "$1" >> "$d/te-calls.log"
case "$1" in
  app) sleep 7 ;;
esac
exit 0
