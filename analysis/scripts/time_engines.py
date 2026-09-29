"""Time each trial's release binary on the perf tests (binary < file.sql, 3 runs, median)
and on the whole m01-m07 suite (sequential, via the harness's sqlref.run_case, 3 runs).
Writes analysis/perf_times.json and analysis/perf_times.csv.

Usage: python3 analysis/scripts/time_engines.py <scratch_ws_dir>
"""
import csv, glob, json, os, statistics, subprocess, sys, time

sys.path.insert(0, "/Users/dii/git/bench/harness")
import sqlref  # noqa: E402

WS = sys.argv[1]
CASES = "/Users/dii/git/bench/tests/cases"
TRIALS = ["rust-t1", "rust-t2", "rust-t3", "moonbit-t1", "moonbit-t2", "moonbit-t3"]
BIN = {"rust": "target/release/minisql", "moonbit": "_build/native/release/build/cmd/main/main.exe"}
perf = sorted(glob.glob(f"{CASES}/m06/perf_*.sql") + glob.glob(f"{CASES}/m07/perf_*.sql"))
res = {"perf": {}, "suite": {}}
TIMEOUT = 30  # seconds; a timed-out run is recorded as 30 s and marked incorrect


def binary(t):
    return os.path.join(WS, t, BIN[t.split("-")[0]])


for t in TRIALS:
    b = binary(t)
    res["perf"][t] = {}
    for f in perf:
        key = f.split("cases/")[1][:-4]
        exp = sqlref.normalize(open(f[:-4] + ".expected").read())
        runs, ok = [], None
        for _ in range(3):
            if runs and runs[-1] > 10:
                break  # very slow (algorithmic outlier): one run is enough
            t0 = time.perf_counter()
            try:
                r = subprocess.run([b], stdin=open(f, "rb"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=TIMEOUT)
                dt = time.perf_counter() - t0
                out = r.stdout.decode("utf-8", "replace")
                ok = (sqlref.normalize(out) == exp) and r.returncode == 0
            except subprocess.TimeoutExpired:
                dt, ok = float(TIMEOUT), False
            runs.append(dt)
        res["perf"][t][key] = {"median_s": statistics.median(runs), "runs": runs, "correct": ok}
        print(t, key, round(statistics.median(runs), 3), ok, flush=True)

cases = []
for m in range(1, 8):
    for f in sorted(glob.glob(f"{CASES}/m{m:02d}/*.sql")):
        cases.append(f)
for t in TRIALS:
    b = binary(t)
    totals, per = [], {}
    for rep in range(3):
        tot = 0.0
        for f in cases:
            tc = sqlref.parse_test(f)
            t0 = time.perf_counter()
            out, err = sqlref.run_case(tc, [b])
            dt = time.perf_counter() - t0
            tot += dt
            key = f.split("cases/")[1][:-4]
            per.setdefault(key, []).append(dt)
        totals.append(tot)
    nonperf = sum(statistics.median(v) for k, v in per.items() if "/perf_" not in k)
    res["suite"][t] = {"total_s_runs": totals, "total_s_median": statistics.median(totals),
                       "nonperf_sum_of_medians_s": nonperf, "n_cases": len(cases),
                       "per_case_median": {k: statistics.median(v) for k, v in per.items()}}
    print(t, "suite", statistics.median(totals), "non-perf", nonperf, flush=True)

json.dump(res, open("/Users/dii/git/bench/analysis/perf_times.json", "w"), indent=1)
with open("/Users/dii/git/bench/analysis/perf_times.csv", "w", newline="") as fh:
    w = csv.writer(fh)
    w.writerow(["test"] + TRIALS)
    for f in perf:
        key = f.split("cases/")[1][:-4]
        w.writerow([key] + [f"{res['perf'][t][key]['median_s']:.4f}" + ("" if res["perf"][t][key]["correct"] else "*") for t in TRIALS])
    w.writerow(["SUITE m01-m07 total (median of 3)"] + [f"{res['suite'][t]['total_s_median']:.3f}" for t in TRIALS])
    w.writerow(["SUITE non-perf cases (sum of medians)"] + [f"{res['suite'][t]['nonperf_sum_of_medians_s']:.3f}" for t in TRIALS])
