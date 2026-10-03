#!/bin/sh
# Build the HEAD reference tree: export skreeep2 at GA_COMMIT to ~/gate-eval/head, git init it, and compile everything there once.
# Mill output is never copied between trees (it records absolute paths); every other tree compiles cold under its own out.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
h=$GA_ROOT/head
rm -rf "$h"; mkdir -p "$h"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$h" || ga_die "git archive failed"
( cd "$h" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm head ) || ga_die "git init"
( cd "$h" && MILL_OUTPUT_DIR=out ./mill --no-daemon -j 1 --ticker false --color false __.compile + __.test.compile ) || ga_die "HEAD does not compile"
echo "head reference tree: $h"
