#!/usr/bin/env python3
"""Aggregate trial records into CSV and a Markdown report.

Usage: report.py [--runs-dir DIR] [--out results/]
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONFIG = json.load(open(os.path.join(HERE, "config.json")))

SESSION_SUMS = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens",
                "cost_usd", "num_turns", "wall_seconds", "api_calls", "build_attempts", "build_failures",
                "test_runs", "compactions"]


def load_trials(runs: str) -> list[dict]:
    trials = []
    for d in sorted(os.listdir(runs)):
        sp = os.path.join(runs, d, "records", "state.json")
        if os.path.exists(sp):
            trials.append(json.load(open(sp)))
    return trials


def milestone_rows(trials: list[dict]) -> list[dict]:
    rows = []
    for t in trials:
        for n, ms in sorted(t["milestones"].items(), key=lambda kv: int(kv[0])):
            if not ms.get("done"):
                continue
            r = {"arm": t["arm"], "trial": t["trial"], "milestone": int(n),
                 "sessions": len(ms["sessions"]), "nudges": ms["nudges"],
                 "rate_limit_interruptions": sum(1 for s in ms["sessions"] if s.get("rate_limited"))}
            for k in SESSION_SUMS:
                r[k] = sum((s.get(k) or 0) for s in ms["sessions"])
            r["total_input_tokens"] = r["input_tokens"] + r["cache_creation_input_tokens"] + r["cache_read_input_tokens"]
            # Cost up to the first run where every visible test passed (later sessions count
            # only if green was not reached earlier). Agents often keep hardening after that.
            r["green_input_tokens"], r["green_api_calls"], r["reached_green"] = 0, 0, False
            for sess in ms["sessions"]:
                if sess.get("green_input_tokens") is not None:
                    r["green_input_tokens"] += sess["green_input_tokens"]
                    r["green_api_calls"] += sess["green_api_calls"]
                    r["reached_green"] = True
                    break
                r["green_input_tokens"] += (sess.get("input_tokens", 0) + sess.get("cache_read_input_tokens", 0)
                                            + sess.get("cache_creation_input_tokens", 0))
                r["green_api_calls"] += sess.get("api_calls", 0)
            r["max_context_tokens"] = max((s.get("max_context_tokens") or 0) for s in ms["sessions"])
            ev = ms["eval"]
            for kind in ("visible", "hidden"):
                r[f"{kind}_passed"] = ev[kind]["passed"]
                r[f"{kind}_total"] = ev[kind]["total"]
                r[f"{kind}_rate"] = round(ev[kind]["passed"] / ev[kind]["total"], 4) if ev[kind]["total"] else None
                # tests of this milestone only
                m = f"m{int(n):02d}"
                pm = ev[kind]["per_milestone"].get(m, [0, 0])
                r[f"{kind}_this_rate"] = round(pm[0] / pm[1], 4) if pm[1] else None
            main = ms["code_totals"]["main"]
            r.update({"src_tokens": main["tokens"], "src_code_lines": main["code"], "src_bytes": main["bytes"],
                      "src_files": main["n_files"], "test_code_lines": ms["code_totals"]["test"]["code"],
                      "lines_added": ms["churn"]["lines_added"], "lines_deleted": ms["churn"]["lines_deleted"],
                      "compliance_ok": ev["compliance"]["ok"]})
            rows.append(r)
    return rows


def trial_rows(rows: list[dict], trials: list[dict]) -> list[dict]:
    primer_tokens = {(t["arm"], t["trial"]): t.get("primer_tokens", 0) for t in trials}
    out = {}
    for r in rows:
        key = (r["arm"], r["trial"])
        t = out.setdefault(key, {"arm": r["arm"], "trial": r["trial"], "milestones_done": 0})
        t["milestones_done"] += 1
        for k in SESSION_SUMS + ["total_input_tokens", "nudges", "rate_limit_interruptions",
                                 "green_input_tokens", "green_api_calls"]:
            t[k] = t.get(k, 0) + (r[k] or 0)
        # final snapshot values come from the latest milestone
        if r["milestone"] >= t.get("last_milestone", 0):
            t["last_milestone"] = r["milestone"]
            for k in ("hidden_passed", "hidden_total", "hidden_rate", "visible_rate", "src_tokens",
                      "src_code_lines", "src_bytes", "src_files", "compliance_ok"):
                t[k] = r[k]
    for t in out.values():
        # The primer sits in CLAUDE.md, so every API call re-reads it.
        t["primer_overhead_tokens"] = primer_tokens.get((t["arm"], t["trial"]), 0) * t["api_calls"]
        t["total_input_excl_primer"] = t["total_input_tokens"] - t["primer_overhead_tokens"]
        t["build_failure_rate"] = round(t["build_failures"] / t["build_attempts"], 3) if t["build_attempts"] else None
        t["output_tokens_per_hidden_pass"] = round(t["output_tokens"] / t["hidden_passed"]) if t["hidden_passed"] else None
        t["cost_per_hidden_pass"] = round(t["cost_usd"] / t["hidden_passed"], 3) if t["hidden_passed"] else None
        t["output_per_src_token"] = round(t["output_tokens"] / t["src_tokens"], 2) if t.get("src_tokens") else None
    return sorted(out.values(), key=lambda t: (t["arm"], t["trial"]))


def fmt(x, digits=0) -> str:
    if x is None:
        return "–"
    if isinstance(x, float) and digits:
        return f"{x:,.{digits}f}"
    return f"{x:,.0f}" if isinstance(x, (int, float)) else str(x)


def mean_sd(vals: list[float]) -> tuple[float | None, float | None]:
    vals = [v for v in vals if v is not None]
    if not vals:
        return None, None
    return st.mean(vals), (st.stdev(vals) if len(vals) > 1 else 0.0)


def write_csv(path: str, rows: list[dict]) -> None:
    if not rows:
        return
    keys = list(dict.fromkeys(k for r in rows for k in r))
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        w.writerows(rows)


def markdown(trials: list[dict], rows: list[dict], trows: list[dict]) -> str:
    arms = sorted({t["arm"] for t in trows}, key=lambda a: (a != "rust", a))  # Rust is the baseline
    out = ["# minisql token-efficiency results", ""]
    if trials:
        t0 = trials[0]
        out.append(f"Model `{t0['model']}`, effort `{t0['effort']}`, {t0.get('claude_version', '')}. "
                   f"Trials: " + ", ".join(f"{a}×{sum(1 for t in trows if t['arm'] == a)}" for a in arms) + ".")
        out.append("")
    metrics_list = [
        ("Output tokens", "output_tokens", 0),
        ("Total input tokens (incl. cache)", "total_input_tokens", 0),
        ("  cache reads", "cache_read_input_tokens", 0),
        ("  cache writes", "cache_creation_input_tokens", 0),
        ("  of which primer re-reads", "primer_overhead_tokens", 0),
        ("Total input tokens excl. primer", "total_input_excl_primer", 0),
        ("Input tokens until first all-green", "green_input_tokens", 0),
        ("API calls until first all-green", "green_api_calls", 0),
        ("API calls (total)", "api_calls", 0),
        ("Est. cost (USD, API prices)", "cost_usd", 2),
        ("Turns", "num_turns", 0),
        ("Wall time (h)", "wall_hours", 2),
        ("Build attempts", "build_attempts", 0),
        ("Build failure rate", "build_failure_rate", 3),
        ("Nudges", "nudges", 1),
        ("Hidden tests passed (final)", "hidden_rate", 3),
        ("Visible tests passed (final)", "visible_rate", 3),
        ("Source tokens (final, non-test)", "src_tokens", 0),
        ("Source code lines (final)", "src_code_lines", 0),
        ("Output tokens / hidden pass", "output_tokens_per_hidden_pass", 0),
        ("Cost / hidden pass (USD)", "cost_per_hidden_pass", 3),
        ("Output tokens / final source token", "output_per_src_token", 2),
    ]
    for t in trows:
        t["wall_hours"] = t["wall_seconds"] / 3600
    out += ["## Totals per trial (mean ± sd across trials)", "",
            "| Metric | " + " | ".join(arms) + (" | ratio " + f"{arms[1]}/{arms[0]}" if len(arms) == 2 else "") + " |",
            "|---|" + "---|" * len(arms) + ("---|" if len(arms) == 2 else "")]
    for label, key, dg in metrics_list:
        cells, means = [], []
        for a in arms:
            m, sd = mean_sd([t.get(key) for t in trows if t["arm"] == a])
            means.append(m)
            cells.append("–" if m is None else f"{fmt(m, dg)} ± {fmt(sd, dg)}")
        ratio = ""
        if len(arms) == 2:
            ratio = " | " + (f"{means[1] / means[0]:.2f}" if means[0] and means[1] is not None else "–")
        out.append(f"| {label} | " + " | ".join(cells) + ratio + " |")
    out.append("")

    out += ["## Per milestone (mean across trials)", "",
            "Output tokens, build failures, and pass rate on that milestone's hidden tests.", "",
            "| M | " + " | ".join(f"{a} out | {a} build fail | {a} hidden" for a in arms)
            + (" | out ratio" if len(arms) == 2 else "") + " |",
            "|---|" + "---|---|---|" * len(arms) + ("---|" if len(arms) == 2 else "")]
    for n, _ in CONFIG["milestones"]:
        cells, outs = [], []
        for a in arms:
            rs = [r for r in rows if r["arm"] == a and r["milestone"] == n]
            o, _ = mean_sd([r["output_tokens"] for r in rs])
            bf, _ = mean_sd([r["build_failures"] for r in rs])
            hr, _ = mean_sd([r["hidden_this_rate"] for r in rs])
            outs.append(o)
            cells += [fmt(o), fmt(bf, 1), "–" if hr is None else f"{hr:.2f}"]
        if all(o is None for o in outs):
            continue
        ratio = ""
        if len(arms) == 2:
            ratio = " | " + (f"{outs[1] / outs[0]:.2f}" if outs[0] and outs[1] is not None else "–")
        out.append(f"| {n} | " + " | ".join(cells) + ratio + " |")
    out.append("")

    issues = [(t["arm"], t["trial"]) for t in trows if not t.get("compliance_ok")]
    if issues:
        out += ["## Compliance", "", "Trials with rule violations in the final snapshot: "
                + ", ".join(f"{a}-t{n}" for a, n in issues) + ". See records/mNN/eval.json.", ""]
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs-dir", default=os.path.expanduser(os.environ.get("MINISQL_RUNS_DIR", CONFIG["runs_dir"])))
    ap.add_argument("--out", default=os.path.join(ROOT, "results"))
    a = ap.parse_args()
    trials = load_trials(a.runs_dir)
    rows = milestone_rows(trials)
    trows = trial_rows(rows, trials)
    os.makedirs(a.out, exist_ok=True)
    write_csv(os.path.join(a.out, "milestones.csv"), rows)
    write_csv(os.path.join(a.out, "trials.csv"), trows)
    n_ms = len(CONFIG["milestones"])
    complete = [t for t in trows if t["milestones_done"] == n_ms]
    if len(complete) < len(trows):
        print(f"note: totals use {len(complete)} complete trials; "
              f"{len(trows) - len(complete)} in progress appear only in the per-milestone table")
    md = markdown(trials, rows, complete)
    with open(os.path.join(a.out, "report.md"), "w") as f:
        f.write(md)
    print(md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
