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
        for sig, grace in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
            try:
                os.killpg(proc.pid, sig)
            except ProcessLookupError:
                break
            try:
                proc.wait(timeout=grace)
                break
            except subprocess.TimeoutExpired:
                continue
        return 124

if __name__ == "__main__":
    sys.exit(main(sys.argv))
