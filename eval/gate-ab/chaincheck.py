#!/usr/bin/env python3
"""chaincheck.py <run-dir> [<earlier-run-dir>...]: chain checks for one chained step (spec 2026-10-11 chained feature
work §3). Each earlier step's hidden spec runs on this step's final tree (status na when that spec had not passed at the
end of its own step), then the erosion figure of the tree. Writes <run-dir>/chain.json; infrastructure trouble goes to
its "error" field, never to a status."""
import json, os, shutil, sys

import erosion
import score


def own_passed(rec):
    return bool(rec.get("hidden_compiled")) and rec.get("hidden_pass_ratio") == 1.0


def earlier_status(compiled, passed, failed, timed_out):
    return "pass" if compiled and not timed_out and failed == 0 and passed > 0 else "fail"


def chain_regressions(earlier):
    return sum(1 for e in earlier if e["status"] == "fail")


def _no_out(repo):
    return lambda d, names: {n for n in names if n == "out" or n.startswith("out-")} if d == repo else set()


def main(rd, earlier_dirs):
    ga_root = os.environ.get("GA_ROOT") or os.path.join(score._home(), "gate-eval")
    repo = os.path.join(rd, "repo")
    tree = os.path.join(rd, "chain-tree")
    out = dict(run_id=os.path.basename(rd), earlier=[], chain_regressions=None, erosion=None, erosion_error=None, error=None)
    try:
        shutil.rmtree(tree, ignore_errors=True)
        shutil.copytree(repo, tree, symlinks=True, ignore=_no_out(repo))
        for ed in earlier_dirs:
            with open(os.path.join(ed, "score.json")) as fh:
                rec = json.load(fh)
            task = rec["task"]
            if not own_passed(rec):
                out["earlier"].append(dict(task=task, status="na", passed=0, failed=0, timed_out=False))
                continue
            ga_home = os.environ.get("GA_HOME") or score.HERE
            module, hidden_spec, _cut, _feature = score.read_task_env(os.path.join(ga_home, "tasks", task, "task.env"))
            src = os.path.join(ga_root, "base", task, "hidden", hidden_spec)
            if not os.path.isfile(src):
                raise score.ScoreError("hidden spec %s missing" % src)
            fq = score.suite_fq(score._read(src))
            if not fq:
                raise score.ScoreError("no suite object in " + src)
            dst = os.path.join(tree, hidden_spec)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copyfile(src, dst)
            log = os.path.join(rd, "chain-%s.log" % task)
            _rc, to = score.run_mill(tree, [module + ".testOnly", fq], "out-chain", log)
            p, f, compiled = score.hidden_counts(score._read(log), fq)
            out["earlier"].append(dict(task=task, status=earlier_status(compiled, p, f, to), passed=p, failed=f, timed_out=to))
            os.remove(dst)  # one spec at a time: a spec that no longer compiles must not mask the next
        out["chain_regressions"] = chain_regressions(out["earlier"])  # only a complete check counts (final review I3)
    except (OSError, ValueError, KeyError, score.ScoreError, score.subprocess.CalledProcessError) as e:
        out["error"] = "%s: %s" % (type(e).__name__, e)
    finally:
        shutil.rmtree(tree, ignore_errors=True)
    try:
        out["erosion"] = erosion.measure(repo, os.path.join(ga_root, "head"))
    except (OSError, erosion.ErosionError) as e:
        out["erosion_error"] = "%s: %s" % (type(e).__name__, e)
    with open(os.path.join(rd, "chain.json"), "w") as fh:
        json.dump(out, fh, indent=2)
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: chaincheck.py <run-dir> [<earlier-run-dir>...]")
    r = main(sys.argv[1], sys.argv[2:])
    print("chain %s: regressions %s, erosion %s%s" % (r["run_id"], r["chain_regressions"], r["erosion"],
                                                     "" if r["error"] is None else ", ERROR " + r["error"]))
