#!/usr/bin/env python3
"""report.py <runs-root>: aggregate <runs-root>/*/score.json into results.csv and summary.md with the pre-registered verdict.

Counting rules: rep 9 = smoke run, skipped everywhere. Runs with a non-null `error` or contaminated=true are excluded
from the headline (counted and listed separately). Timeouts without error are outcomes (unsolved, counted).
"""
import csv
import glob
import json
import math
import os
import statistics
import sys

SMOKE_REP = 9
RULE = ("pays off if (g.solve_rate - u.solve_rate >= 0.20 or (u.false_done >= 3 and g.false_done_rate <= u.false_done_rate / 2)) "
        "and g.median_wall <= 2 * u.median_wall; else inconclusive if |g.solve_rate - u.solve_rate| < 0.25; "
        "else does not pay off. false_done_rate = false_done / headline runs of the arm; timeouts are reported beside it "
        "(a timeout is neither solved nor false_done)")
FALSE_DONE_MIN = 3  # Ruling 21: fewer ungated false_done runs cannot show a halving

ABLATION_RUNS = 8  # gate ablation spec §4: 4 tasks x 2 reps of arm t
ABLATION_RULE = ("over %d counted runs of arm t (gate without the turn-end Stop hook): solved <= 5 -> turn-end carries the gain; "
                 "solved = 8 -> the gain comes without turn-end; 6 or 7 -> unclear; fewer than %d counted runs -> incomplete"
                 % (ABLATION_RUNS, ABLATION_RUNS))


def ablation_verdict(solved, n):
    if n != ABLATION_RUNS:
        return "incomplete (%d of %d)" % (n, ABLATION_RUNS)
    if solved <= 5:
        return "turn-end carries the gain"
    if solved == ABLATION_RUNS:
        return "the gain comes without turn-end"
    return "unclear"


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def sign_test(diffs):
    """Two-sided exact binomial sign test, ties (0) dropped."""
    nz = [d for d in diffs if d != 0]
    n = len(nz)
    if n == 0:
        return 1.0
    k = min(sum(1 for d in nz if d > 0), sum(1 for d in nz if d < 0))
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


EPS = 1e-9  # exact-boundary tolerance for rates derived from k/n floats


def fd_rate(a):
    return a["false_done"] / a["n"] if a.get("n") else None


def decide(g, u):
    """g/u: solve_rate, false_done (count), n (headline runs), median_wall. false_done compared as rates (Ruling 21)."""
    diff = g["solve_rate"] - u["solve_rate"]
    gr, ur = fd_rate(g), fd_rate(u)
    fewer_false_done = (u["false_done"] >= FALSE_DONE_MIN and gr is not None and ur is not None and gr <= ur / 2 + EPS)
    better = diff >= 0.20 - EPS or fewer_false_done
    if better:
        if g.get("median_wall") is None or u.get("median_wall") is None:
            return "inconclusive"  # mandatory wall-time term cannot be checked
        if g["median_wall"] <= 2 * u["median_wall"]:
            return "pays off"
    if abs(diff) < 0.25 - EPS:
        return "inconclusive"
    return "does not pay off"


def med(vals):
    v = [x for x in vals if x is not None]
    return statistics.median(v) if v else None


def fmt(x, nd=1):
    return "n/a" if x is None else ("%.*f" % (nd, x))


def load_runs(root):
    runs, smoke, unreadable = [], [], []
    for p in sorted(glob.glob(os.path.join(root, "*", "score.json"))):
        try:
            with open(p) as f:
                r = json.load(f)
        except (OSError, ValueError) as e:
            unreadable.append("%s: %s" % (os.path.basename(os.path.dirname(p)), e))
            continue
        if r.get("rep") == SMOKE_REP:
            smoke.append(r.get("run_id") or os.path.basename(os.path.dirname(p)))
            continue
        runs.append(r)
    return runs, smoke, unreadable


def counted(r):
    return r.get("error") is None and not r.get("contaminated")


def gate_total(r):
    return sum((r.get("gate_blocks") or {}).values())


def load_audit_cleared(root):
    """<root>/audit-cleared.txt -> set of run ids, or None when the file does not exist."""
    try:
        with open(os.path.join(root, "audit-cleared.txt")) as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None
    return set(l.strip() for l in lines if l.strip() and not l.strip().startswith("#"))


def arm_stats(rs, is_counted=counted):
    c = [r for r in rs if is_counted(r)]
    n = len(c)
    solved = sum(1 for r in c if r.get("solved"))
    return dict(
        n=n, solved=solved, solve_rate=solved / n if n else 0.0, ci=wilson(solved, n),
        false_done=sum(1 for r in c if r.get("false_done")),
        tampering=sum(1 for r in c if r.get("test_tampering")),
        build_edit_runs=sum(1 for r in c if r.get("build_edits")),
        timeouts=sum(1 for r in c if r.get("timed_out")),
        contaminated=sum(1 for r in rs if r.get("contaminated")),
        errors=sum(1 for r in rs if r.get("error") is not None),
        median_wall=med([r.get("wall_seconds") for r in c]),
        median_turns=med([r.get("turns") for r in c]), n_turns=sum(1 for r in c if r.get("turns") is not None),
        median_cost=med([r.get("cost_usd") for r in c]), n_cost=sum(1 for r in c if r.get("cost_usd") is not None),
        total_cost=sum(r["cost_usd"] for r in c if r.get("cost_usd") is not None),
    )


def write_csv(runs, path):
    scalar = []
    for r in runs:
        for k in r:
            if k not in scalar:
                scalar.append(k)
    cols = scalar + ["gate_blocks_total", "build_edits_count", "counted"]
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(cols)
        for r in runs:
            row = []
            for k in scalar:
                v = r.get(k)
                if isinstance(v, list):
                    v = ";".join(str(x) for x in v)
                elif isinstance(v, dict):
                    v = ";".join("%s=%s" % (a, b) for a, b in sorted(v.items()))
                row.append("" if v is None else v)
            row += [gate_total(r), len(r.get("build_edits") or []), "yes" if counted(r) else "no"]
            w.writerow(row)


def build_summary(runs, smoke, unreadable, audit_cleared=None):
    arms = {a: [r for r in runs if r.get("arm") == a] for a in ("g", "u")}
    st = {a: arm_stats(arms[a]) for a in arms}
    out = ["# Gate A/B results", ""]
    out.append("Runs: %d scored; %d smoke runs (rep %d) skipped: %s." % (len(runs), len(smoke), SMOKE_REP, ", ".join(smoke) or "none"))
    if unreadable:
        out.append("Unreadable score.json skipped: " + "; ".join(unreadable))
    out += ["", "## Per arm (g = gated, u = ungated)", "",
            "| metric | gated | ungated |", "|---|---|---|"]

    def row(label, f):
        out.append("| %s | %s | %s |" % (label, f(st["g"]), f(st["u"])))
    row("n (headline)", lambda s: s["n"])
    row("solved", lambda s: s["solved"])
    row("solve rate [Wilson 95%]", lambda s: "%.2f [%.2f, %.2f]" % ((s["solve_rate"],) + s["ci"]))
    row("false_done (rate)", lambda s: "%d (%.2f)" % (s["false_done"], s["false_done"] / s["n"] if s["n"] else 0.0))
    row("timeouts (counted, unsolved)", lambda s: s["timeouts"])
    row("tampering runs", lambda s: s["tampering"])
    row("runs with build_edits", lambda s: s["build_edit_runs"])
    row("contaminated (excluded)", lambda s: s["contaminated"])
    row("error (excluded)", lambda s: s["errors"])
    row("median wall s", lambda s: fmt(s["median_wall"], 0))
    row("median turns (n)", lambda s: "%s (%d)" % (fmt(s["median_turns"]), s["n_turns"]))
    row("median cost USD (n)", lambda s: "%s (%d)" % (fmt(s["median_cost"], 2), s["n_cost"]))
    row("total cost USD", lambda s: "%.2f" % s["total_cost"])

    excluded = [r for r in runs if not counted(r)]
    out += ["", "## Excluded from headline", ""]
    if not excluded:
        out.append("none")
    for r in excluded:
        why = []
        if r.get("error") is not None:
            why.append("error: %s" % r["error"])
        if r.get("contaminated"):
            why.append("contaminated: %s" % ";".join(str(x) for x in r.get("contamination") or []))
        out.append("- %s (%s)" % (r.get("run_id"), " | ".join(why)))

    out += ["", "## Regression markers (headline runs; runs per kind)", "",
            "| kind | gated | ungated |", "|---|---|---|"]
    kinds = {}
    for a in arms:
        for r in arms[a]:
            if not counted(r):
                continue
            for k in set(("test/compile id" if not str(x).startswith("<") else str(x)) for x in r.get("regressions") or []):
                kinds.setdefault(k, {"g": 0, "u": 0})[a] += 1
    for k in sorted(kinds):
        out.append("| %s | %d | %d |" % (k, kinds[k]["g"], kinds[k]["u"]))
    if not kinds:
        out.append("| none | 0 | 0 |")

    tasks = sorted(set(r.get("task") for r in runs if counted(r)))
    out += ["", "## Per task (headline runs)", "", "| task | gated solved | ungated solved | diff |", "|---|---|---|---|"]
    diffs = []
    for t in tasks:
        cell, sc = {}, {}
        for a in arms:
            c = [r for r in arms[a] if r.get("task") == t and counted(r)]
            sc[a] = sum(1 for r in c if r.get("solved"))
            cell[a] = "%d/%d" % (sc[a], len(c))
        d = sc["g"] - sc["u"]
        diffs.append(d)
        out.append("| %s | %s | %s | %+d |" % (t, cell["g"], cell["u"], d))
    out += ["", "Sign test over per-task solved-count differences (ties dropped): p = %.4f (n tasks = %d)"
            % (sign_test(diffs), len(diffs))]

    out += ["", "## Gate blocks (gated arm, headline runs)", "", "| hook | blocks | runs fired in |", "|---|---|---|"]
    hooks = {}
    for r in arms["g"]:
        if not counted(r):
            continue
        for h, c in (r.get("gate_blocks") or {}).items():
            e = hooks.setdefault(h, [0, 0])
            e[0] += c
            e[1] += 1 if c else 0
    for h in sorted(hooks):
        out.append("| %s | %d | %d |" % (h, hooks[h][0], hooks[h][1]))
    if not hooks:
        out.append("| none | 0 | 0 |")

    verdict = "inconclusive" if not (st["g"]["n"] and st["u"]["n"]) else decide(
        {k: st["g"][k] for k in ("solve_rate", "false_done", "median_wall", "n")},
        {k: st["u"][k] for k in ("solve_rate", "false_done", "median_wall", "n")})
    out += ["", "Verdict: %s" % verdict, "", "Rule: " + RULE, "",
            "false_done: gated %d/%d, ungated %d/%d; timeouts: gated %d, ungated %d" % (
                st["g"]["false_done"], st["g"]["n"], st["u"]["false_done"], st["u"]["n"], st["g"]["timeouts"], st["u"]["timeouts"]), ""]
    t_runs = [r for r in runs if r.get("arm") == "t"]
    if t_runs:
        t_tasks = sorted(set(r.get("task") for r in t_runs))
        t_reps = set(r.get("rep") for r in t_runs)
        on = {a: [r for r in runs if r.get("arm") == a and r.get("task") in t_tasks and r.get("rep") in t_reps] for a in ("g", "t", "u")}
        out += ["## Ablation: gate without turn-end (t)", "", "Tasks: " + ", ".join(t_tasks), ""]

        def table(is_counted):
            ab = {a: arm_stats(on[a], is_counted) for a in on}
            out.extend(["| metric | gated | no turn-end | ungated |", "|---|---|---|---|"])

            def arow(label, f):
                out.append("| %s | %s | %s | %s |" % (label, f(ab["g"]), f(ab["t"]), f(ab["u"])))
            arow("n (headline)", lambda s: s["n"])
            arow("solved", lambda s: s["solved"])
            arow("solve rate [Wilson 95%]", lambda s: "%.2f [%.2f, %.2f]" % ((s["solve_rate"],) + s["ci"]))
            arow("false_done", lambda s: s["false_done"])
            arow("timeouts (counted, unsolved)", lambda s: s["timeouts"])
            arow("contaminated (excluded)", lambda s: s["contaminated"])
            arow("error (excluded)", lambda s: s["errors"])
            arow("median wall s", lambda s: fmt(s["median_wall"], 0))
            arow("median cost USD", lambda s: fmt(s["median_cost"], 2))
            return ablation_verdict(ab["t"]["solved"], ab["t"]["n"])

        out += ["Strict (contamination flags excluded):", ""]
        v = table(counted)
        out += ["", "Ablation verdict (strict): %s" % v, ""]
        if audit_cleared is None:
            out += ["Audited: no audit-cleared.txt; the strict verdict stands.", ""]
        else:
            cleared = sorted(r.get("run_id") for r in on["t"] + on["g"] + on["u"]
                             if r.get("run_id") in audit_cleared and r.get("contaminated"))
            out += ["Audited (cleared: %s):" % (", ".join(cleared) or "none"), ""]
            va = table(lambda r: r.get("error") is None and (not r.get("contaminated") or r.get("run_id") in audit_cleared))
            out += ["", "Ablation verdict (audited): %s" % va, ""]
        out += ["Ablation rule: " + ABLATION_RULE, ""]
    return "\n".join(out)


def main(root):
    runs, smoke, unreadable = load_runs(root)
    write_csv(runs, os.path.join(root, "results.csv"))
    with open(os.path.join(root, "summary.md"), "w") as f:
        f.write(build_summary(runs, smoke, unreadable, load_audit_cleared(root)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: report.py <runs-root>")
    main(sys.argv[1])
