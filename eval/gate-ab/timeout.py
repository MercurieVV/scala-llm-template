#!/usr/bin/env python3
"""timeout.py <seconds> -- <cmd...>: run cmd in its own process group; past a wall-clock deadline SIGTERM the group, wait up to 10 s, always SIGKILL the group; exit 124."""
import os, signal, subprocess, sys, time

def killpg(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass

def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        sys.stderr.write("usage: timeout.py <seconds> -- <cmd...>\n")
        return 2
    deadline = time.time() + float(argv[1])
    proc = subprocess.Popen(argv[3:], start_new_session=True)
    while time.time() < deadline:
        rc = proc.poll()
        if rc is not None:
            return rc
        time.sleep(0.5)
    killpg(proc.pid, signal.SIGTERM)
    grace = time.time() + 10
    while time.time() < grace and proc.poll() is None:
        time.sleep(0.5)
    killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    return 124

if __name__ == "__main__":
    sys.exit(main(sys.argv))
