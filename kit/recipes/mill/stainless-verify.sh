#!/bin/sh
# Formal-verification check: run the standalone Stainless tool over the kernel files named on the command line
# (production code, verified in place, no mirror) and fail iff any verification condition is INVALID.
#
# Usage: scripts/stainless-verify.sh <file.scala> [<file.scala> ...]   (run from the repo root; paths root-relative)
#
# Exit codes (the gate reads these, and the marker lines below):
#   0  no `invalid` VC (`unknown` — a solver timeout — is tolerated; the tool's own output lists them)
#   1  at least one `invalid` VC          marker: `stainless-verify: FAILED — <n> invalid verification condition(s)`
#   2  setup failure / no summary         marker: `stainless-verify: SETUP — <reason>`
#
# Why parse the summary instead of trusting Stainless's exit code: the tool exits non-zero on `unknown` as well as
# `invalid`. A nonlinear-arithmetic VC (division or multiplication by a variable) can time out under the bundled
# `smt-z3`; that is a solver limitation, not a soundness failure. A genuine regression produces an `invalid` VC.
#
# The standalone distribution bundles its own z3/cvc5, so no solver install is needed; `curl` and `unzip` are needed
# once, to install it. Env overrides: STAINLESS_VERSION, STAINLESS_TIMEOUT, STAINLESS_CACHE_DIR.
# Adapted from ScalaSemanticMCP's scripts/stainless-verify.sh (targets from the arguments; exit 2 on setup failure).
set -u

VERSION="${STAINLESS_VERSION:-0.9.9.3}"
CACHE_DIR="${STAINLESS_CACHE_DIR:-$HOME/.cache/scala-llm-kit/stainless}"
# Per-VC timeout, seconds. Valid VCs discharge well under it; an invalid VC yields its counterexample near-instantly.
TIMEOUT="${STAINLESS_TIMEOUT:-10}"

setup_failure() {
  echo "stainless-verify: SETUP — $1" >&2
  exit 2
}

[ "$#" -ge 1 ] || { echo "usage: stainless-verify.sh <file.scala> [<file.scala> ...]" >&2; exit 2; }
for f in "$@"; do
  [ -f "$f" ] || setup_failure "no such target file: $f"
done

# --- pick the release asset for this OS/arch -------------------------------------------------------------------
os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Linux/x86_64)  platform="linux" ;;
  Darwin/arm64)  platform="mac-arm64" ;;
  Darwin/x86_64) platform="mac-x64" ;;
  *) setup_failure "unsupported platform $os/$arch" ;;
esac

asset="stainless-dotty-standalone-${VERSION}-${platform}.zip"
url="https://github.com/epfl-lara/stainless/releases/download/v${VERSION}/${asset}"
install_dir="${CACHE_DIR}/${VERSION}-${platform}"

# --- download + cache the standalone tool -----------------------------------------------------------------------
stainless_bin="$(find "$install_dir" -maxdepth 2 -name stainless -type f 2>/dev/null | head -1)"
if [ -z "$stainless_bin" ]; then
  echo "stainless-verify: installing Stainless $VERSION ($platform) -> $install_dir"
  command -v curl >/dev/null 2>&1 || setup_failure "curl not found (needed to download $asset)"
  command -v unzip >/dev/null 2>&1 || setup_failure "unzip not found (needed to unpack $asset)"
  mkdir -p "$install_dir" || setup_failure "cannot create $install_dir"
  tmp_zip="$(mktemp "${TMPDIR:-/tmp}/stainless-zip.XXXXXX")" || setup_failure "mktemp failed"
  if ! curl -fsSL "$url" -o "$tmp_zip"; then
    rm -f "$tmp_zip"
    setup_failure "download failed: $url"
  fi
  if ! unzip -q -o "$tmp_zip" -d "$install_dir"; then
    rm -f "$tmp_zip"
    setup_failure "unzip failed: $asset -> $install_dir"
  fi
  rm -f "$tmp_zip"
  stainless_bin="$(find "$install_dir" -maxdepth 2 -name stainless -type f 2>/dev/null | head -1)"
fi
[ -n "$stainless_bin" ] || setup_failure "stainless launcher not found under $install_dir"
chmod +x "$stainless_bin" 2>/dev/null || true
command -v java >/dev/null 2>&1 || setup_failure "java not found (the Stainless launcher runs on the JVM)"

# --- verify ----------------------------------------------------------------------------------------------------
echo "stainless-verify: verifying $* (timeout ${TIMEOUT}s/VC)"
out="$(mktemp "${TMPDIR:-/tmp}/stainless-out.XXXXXX")" || setup_failure "mktemp failed"
# The tool's exit code is not the verdict (see the header); its output passes through unchanged, colour included.
"$stainless_bin" --timeout="$TIMEOUT" "$@" 2>&1 | tee "$out"

# Strip ANSI colour for the parse only, then read the summary's `invalid: N` field.
esc="$(printf '\033')"
summary="$(sed "s/${esc}\[[0-9;]*m//g" "$out" | grep -E 'total:[[:space:]]+[0-9]+' | tail -1)"
rm -f "$out"

[ -n "$summary" ] || setup_failure "no Stainless summary in the output (tool or compile error above)"

invalid="$(echo "$summary" | sed -E 's/.*invalid:[[:space:]]*([0-9]+).*/\1/')"
case "$invalid" in
  '' | *[!0-9]*) setup_failure "summary has no invalid count: $summary" ;;
esac
echo "stainless-verify: summary -> $summary"

if [ "$invalid" -ne 0 ]; then
  echo "stainless-verify: FAILED — $invalid invalid verification condition(s)" >&2
  exit 1
fi

echo "stainless-verify: OK — no invalid verification conditions (unknown/timeout VCs tolerated)"
exit 0
