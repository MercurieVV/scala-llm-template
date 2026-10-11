#!/usr/bin/env python3
"""chain_report.py <root> <task>...: the chained-feature-work table and the pre-registered verdicts (spec 2026-10-11
chained feature work §4). Writes <root>/chain-report.md. Item 15 needs the transcripts; the report lists the false_done steps."""
import json, os, statistics, sys

ARMS = ("u", "gs")


def _load(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


def step_failures(score, chain):
    if chain is None or chain.get("error") is not None or chain.get("chain_regressions") is None or score.get("regression_count", -1) < 0:
        return None
    return (0 if score.get("solved") else 1) + score["regression_count"] + chain["chain_regressions"]


def gate_verdict(fail_u, fail_gs):
    d = fail_u - fail_gs
    return "gate pays on chains" if d >= 2 else "no gain" if d <= 0 else "unclear"


def gate_line(fail_u, fail_gs, unknown):
    if unknown:
        return "Gate: incomplete — unscored steps %s (u - gs = %d so far)" % (", ".join(unknown), fail_u - fail_gs)
    return "Gate: %s (u - gs = %d)" % (gate_verdict(fail_u, fail_gs), fail_u - fail_gs)


def erosion_rises(chains, ref_last):
    counted = rising = 0
    for c in chains:
        if not c or c[0] is None or c[-1] is None:
            continue
        counted += 1
        if c[-1] > c[0] and c[-1] > ref_last:
            rising += 1
    return rising, counted


def item16_verdict(rising, counted):
    return "build item 16" if rising >= 3 else "do not build item 16"


def main(root, tasks):
    lines = ["# Chained feature work", "", "| arm | chain | step | task | solved | false_done | regressions | chain regressions | erosion | wall s | cost USD |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    fails = {a: 0 for a in ARMS}; unknown = []; false_done = []; ero_chains = []; walls = {a: [] for a in ARMS}; costs = {a: [] for a in ARMS}
    reps = sorted({int(n.rsplit("-", 1)[1]) for n in os.listdir(os.path.join(root, "runs")) if n.rsplit("-", 1)[-1].isdigit()})
    for arm in ARMS:
        for rep in reps:
            chain_ero = []
            for k, t in enumerate(tasks, 1):
                rid = "%s-%s-%d" % (t, arm, rep)
                s = _load(os.path.join(root, "runs", rid, "score.json")) or {}
                c = _load(os.path.join(root, "runs", rid, "chain.json"))
                f = step_failures(s, c) if s and s.get("error") is None else None
                if f is None:
                    unknown.append(rid)
                else:
                    fails[arm] += f
                if s.get("false_done"):
                    false_done.append(rid)
                e = ((c or {}).get("erosion") or {}).get("erosion")
                chain_ero.append(e)
                if s.get("wall_seconds") is not None:
                    walls[arm].append(s["wall_seconds"]); costs[arm].append(s.get("cost_usd") or 0.0)
                lines.append("| %s | %d | %d | %s | %s | %s | %s | %s | %s | %s | %s |" % (
                    arm, rep, k, t, s.get("solved"), s.get("false_done"), s.get("regression_count"),
                    (c or {}).get("chain_regressions"), e, s.get("wall_seconds"),
                    None if s.get("cost_usd") is None else round(s["cost_usd"], 3)))
            ero_chains.append(chain_ero)
    ref = _load(os.path.join(root, "chain-reference-erosion.json")) or []
    ref_last = ref[-1]["erosion"] if ref else 0.0
    rising, counted = erosion_rises(ero_chains, ref_last)
    lines += ["", "u: failures %d" % fails["u"], "gs: failures %d" % fails["gs"],
              gate_line(fails["u"], fails["gs"], unknown),
              "Item 16: %s (erosion rising in %d of %d chains; reference step %d erosion %s)" % (
                  item16_verdict(rising, counted), rising, counted, len(ref), ref_last),
              "Item 15: read the transcripts of false_done: %s" % (", ".join(false_done) or "none"),
              "Unscored or errored steps: %s" % (", ".join(unknown) or "none")]
    for a in ARMS:
        if walls[a]:
            lines.append("%s: median wall %s s, median cost USD %.3f" % (a, statistics.median(walls[a]), statistics.median(costs[a])))
    text = "\n".join(lines) + "\n"
    with open(os.path.join(root, "chain-report.md"), "w") as fh:
        fh.write(text)
    return text


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit("usage: chain_report.py <root> <task>...")
    print(main(sys.argv[1], sys.argv[2:]), end="")
