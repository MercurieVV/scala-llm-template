#!/bin/sh
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
printf '%s\n' "$1" >> "$d/te-calls.log"
exit 0
