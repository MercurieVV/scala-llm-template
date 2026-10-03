#!/bin/sh
# Compile skreeep2 at GA_COMMIT once in a sacrificial build dir; ~/gate-eval/cache/out is the warm Mill output every run copies,
# ~/gate-eval/head is the full HEAD export with its own copy of it. Mill records absolute paths in the output, and a run in a copy
# overwrites the directory those paths name, so the paths must name the sacrificial build dir, never head or cache/out.
set -u
GA_LIB_PATH=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh; . "$GA_LIB_PATH"
h=$GA_ROOT/head; b=$GA_ROOT/cache-build
rm -rf "$h" "$GA_ROOT/cache" "$b"; mkdir -p "$h" "$b" "$GA_ROOT/cache"
git -C "$GA_SKREEEP2" archive "$GA_COMMIT" | tar -x -C "$h" || ga_die "git archive failed"
( cd "$h" && git init -q && git add -A && git -c user.name=gate-eval -c user.email=gate-eval@local -c commit.gpgsign=false commit -qm head ) || ga_die "git init"
cp -R "$h/." "$b/"
( cd "$b" && MILL_OUTPUT_DIR=out ./mill --no-daemon -j 1 --ticker false --color false __.compile + __.test.compile ) || ga_die "HEAD does not compile"
cp -R "$b/out" "$GA_ROOT/cache/out"
cp -R "$b/out" "$h/out"
echo "warm cache: $GA_ROOT/cache/out"
