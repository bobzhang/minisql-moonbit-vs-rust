"""Run the controlled micro-benchmarks in analysis/microbench/ (same workload, no
index/plan choices that differ much between engines) on every trial's release
binary: 5 runs, median, output checked against python sqlite3.
Writes analysis/microbench_times.json/.csv.
Usage: python3 analysis/scripts/microbench.py <scratch_ws_dir>"""
import csv, glob, json, os, statistics, subprocess, sys, time
sys.path.insert(0, "/Users/dii/git/bench/harness")
import sqlref  # noqa: E402
WS = sys.argv[1]
MB = "/Users/dii/git/bench/analysis/microbench"
TRIALS = ["rust-t1", "rust-t2", "rust-t3", "moonbit-t1", "moonbit-t2", "moonbit-t3"]
BIN = {"rust": "target/release/minisql", "moonbit": "_build/native/release/build/cmd/main/main.exe"}
files = sorted(glob.glob(f"{MB}/mb_*.sql"))
res = {}
for t in TRIALS:
    b = os.path.join(WS, t, BIN[t.split("-")[0]])
    res[t] = {}
    for f in files:
        exp = sqlref.normalize(open(f[:-4] + ".expected").read())
        runs, ok = [], True
        for _ in range(5):
            t0 = time.perf_counter()
            r = subprocess.run([b], stdin=open(f, "rb"), stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
            runs.append(time.perf_counter() - t0)
            ok = ok and sqlref.normalize(r.stdout.decode("utf-8", "replace")) == exp
        k = os.path.basename(f)[:-4]
        res[t][k] = {"median_s": statistics.median(runs), "runs": runs, "correct": ok}
        print(t, k, round(statistics.median(runs), 3), ok, flush=True)
json.dump(res, open("/Users/dii/git/bench/analysis/microbench_times.json", "w"), indent=1)
with open("/Users/dii/git/bench/analysis/microbench_times.csv", "w", newline="") as fh:
    w = csv.writer(fh); w.writerow(["bench"] + TRIALS + ["moonbit/rust (mean of trial medians)"])
    for f in files:
        k = os.path.basename(f)[:-4]
        v = [res[t][k]["median_s"] for t in TRIALS]
        w.writerow([k] + [f"{x:.4f}" + ("" if res[t][k]["correct"] else "*") for x, t in zip(v, TRIALS)] +
                   [f"{statistics.mean(v[3:]) / statistics.mean(v[:3]):.2f}"])
