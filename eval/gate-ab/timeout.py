#!/usr/bin/env python3
"""timeout.py <seconds> -- <cmd...>: run cmd in its own process group; on timeout SIGTERM the group, wait 10 s, SIGKILL; exit 124."""
import os, signal, subprocess, sys

def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        sys.stderr.write("usage: timeout.py <seconds> -- <cmd...>\n")
        return 2
    limit = float(argv[1])
    proc = subprocess.Popen(argv[3:], start_new_session=True)
    try:
        return proc.wait(timeout=limit)
    except subprocess.TimeoutExpired:
        # Send SIGTERM and give grace period
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return 124
        try:
            proc.wait(timeout=10)
            return 124
        except subprocess.TimeoutExpired:
            pass
        # Always send SIGKILL after SIGTERM grace period
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        return 124

if __name__ == "__main__":
    sys.exit(main(sys.argv))
