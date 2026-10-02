#!/bin/sh
# mill-gate.sh <mill args…>: the ONE way the engine starts Mill (spec 2026-10-02 structural holdout seal §4.2).
# It runs the project's Mill (`resolve_real_mill`: ./mill, else mill on PATH) with `--no-daemon` FIRST and
# MILL_OUTPUT_DIR set to the agent's output directory (`dsh_agent_output_dir`: out-agent with a sealed holdout,
# else out) -- or, for the holdout run, to `dsh_holdout_output_dir` (out-holdout). Hooks run outside the agent's sandbox, so a Mill server they left behind would run with full
# access — and a sandboxed agent client that found it ran the sealed holdout suite. `--no-daemon` leaves no server; the shared
# directory keeps one compile cache with the agent's own builds.
set -u
_mg_engine=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$_mg_engine/lib.sh"
_mg_root=$(gate_root)
_mg_real=$(resolve_real_mill "$_mg_root") || {
  printf 'mill-gate: no Mill to run — neither %s/mill nor a mill on PATH\n' "$_mg_root" >&2
  exit 127
}
# The gate's holdout run (the only caller with DSH_HOLDOUT_DIR set -- every hook unsets an inherited one) builds
# in its own directory: --no-daemon writes <output dir>/mill-console-tail with the console's last lines, holdout
# source after a failing run (measured, Mill 1.1.8), and the agent may read its own directory.
if [ -n "${DSH_HOLDOUT_DIR:-}" ]; then
  MILL_OUTPUT_DIR=$(dsh_holdout_output_dir "$_mg_root")
else
  MILL_OUTPUT_DIR=$(dsh_agent_output_dir "$_mg_root")
fi
export MILL_OUTPUT_DIR
# resolve_real_mill answers the RELATIVE ./mill, and Mill takes its project from the cwd: run it from the root.
cd "$_mg_root" 2>/dev/null || {
  printf 'mill-gate: cannot cd to %s — the project root\n' "$_mg_root" >&2
  exit 127
}
exec "$_mg_real" --no-daemon "$@"
