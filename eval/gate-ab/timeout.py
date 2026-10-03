#!/usr/bin/env python3
"""timeout.py <seconds> -- <cmd...>: run cmd in its own process group; past a wall-clock deadline SIGTERM the group, wait up to 10 s, always SIGKILL the group; exit 124."""
import os, signal, subprocess, sys, time

def killpg(pid, sig):
    try:
        os.killpg(pid, sig)
    except ProcessLookupError:
        pass

def reap(proc):
    killpg(proc.pid, signal.SIGTERM)
    grace = time.time() + 10
    while time.time() < grace and proc.poll() is None:
        time.sleep(0.5)
    killpg(proc.pid, signal.SIGKILL)
    proc.wait()

def main(argv):
    if len(argv) < 4 or argv[2] != "--":
        sys.stderr.write("usage: timeout.py <seconds> -- <cmd...>\n")
        return 2
    deadline = time.time() + float(argv[1])
    proc = subprocess.Popen(argv[3:], start_new_session=True)

    def on_term(signum, frame):  # SIGTERM to us reaps the child group exactly like SIGINT
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, on_term)
    try:
        while time.time() < deadline:
            rc = proc.poll()
            if rc is not None:
                return rc
            time.sleep(0.5)
        reap(proc)
        return 124
    except KeyboardInterrupt:  # Ctrl-C / SIGINT to us: the child group is in its own session, so take it down too
        reap(proc)
        return 130

if __name__ == "__main__":
    sys.exit(main(sys.argv))
