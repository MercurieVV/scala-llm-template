#!/bin/sh
# Sleeps past DSH_TESTS_CAP=2 (the env this case sets), and spawns a grandchild (te-child.sh, a
# `sleep 30`) first -- the kill has to reach it too, or it is a leftover the post_gate check catches.
d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
sh "$d/te-child.sh" &
sleep 5
exit 0
