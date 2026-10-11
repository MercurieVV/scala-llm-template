#!/usr/bin/env python3
"""erosion.py <tree> <head>: the erosion figure of the main .scala files that differ from <head> (spec 2026-10-11 chained
feature work §3). Per-method CC and SLOC come from erosion.scala (scala-cli + scalameta); mass = CC * sqrt(SLOC);
erosion = share of mass in methods with CC > 10 (SlopCodeBench). Env GA_SCALA_CLI (default scala-cli)."""
import json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
CC_ERODED = 10


class ErosionError(Exception):
    """scala-cli failed or printed something that is not the expected JSON."""


def _skipped_dir(name):
    return name.startswith(".") or name == "out" or name.startswith("out-") or name == "test"


def _bytes(path):
    with open(path, "rb") as fh:
        return fh.read()


def changed_main_files(tree, head):
    found = []
    for root, dirs, files in os.walk(tree):
        dirs[:] = sorted(d for d in dirs if not _skipped_dir(d))
        for f in sorted(files):
            if not f.endswith(".scala"):
                continue
            p = os.path.join(root, f)
            h = os.path.join(head, os.path.relpath(p, tree))
            if not os.path.isfile(h) or _bytes(p) != _bytes(h):
                found.append(p)
    return sorted(found)


def aggregate(methods):
    total = eroded = 0.0
    for m in methods:
        mass = m["cc"] * math.sqrt(m["sloc"])
        total += mass
        if m["cc"] > CC_ERODED:
            eroded += mass
    return {"methods": len(methods), "total_mass": round(total, 3), "erosion": round(eroded / total, 4) if total else 0.0}


def method_metrics(files):
    cmd = [os.environ.get("GA_SCALA_CLI", "scala-cli"), "run", "-q", os.path.join(HERE, "erosion.scala"), "--"] + list(files)
    try:
        r = subprocess.run(cmd, capture_output=True, text=True)
    except OSError as e:
        raise ErosionError("cannot run %s: %s" % (cmd[0], e))
    if r.returncode != 0:
        raise ErosionError("erosion.scala exit %d: %s" % (r.returncode, r.stderr.strip()[-500:]))
    try:
        return json.loads(r.stdout.strip().splitlines()[-1])["methods"]
    except (ValueError, KeyError, IndexError):
        raise ErosionError("erosion.scala printed no JSON: %r" % r.stdout[-300:])


def measure(tree, head):
    files = changed_main_files(tree, head)
    return aggregate(method_metrics(files)) if files else aggregate([])


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: erosion.py <tree> <head>")
    try:
        print(json.dumps(measure(sys.argv[1], sys.argv[2])))
    except ErosionError as e:
        sys.exit("erosion.py: %s" % e)
