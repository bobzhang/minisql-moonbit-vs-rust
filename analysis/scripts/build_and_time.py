"""Build each trial's final engine (release) in a scratch copy and time clean and
incremental builds, plus `check`. Writes analysis/build_times.json.

Usage: python3 analysis/scripts/build_and_time.py <scratch_ws_dir>
(scratch_ws_dir holds copies of ~/minisql-bench-runs/<trial>/work named <trial>)
"""
import json, os, subprocess, sys, time

WS = sys.argv[1]
OUT = "/Users/dii/git/bench/analysis/build_times.json"
TRIALS = ["rust-t1", "rust-t2", "rust-t3", "moonbit-t1", "moonbit-t2", "moonbit-t3"]


def run(cmd, cwd):
    t0 = time.time()
    r = subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return time.time() - t0, r.returncode, r.stdout[-2000:]


def main_source(trial, root):
    # a central file every other file depends on (value representation)
    cands = []
    for d, _, fs in os.walk(root):
        if any(x in d for x in ("_build", "target", "/io", "tests", "tools")):
            continue
        for f in fs:
            if f.endswith((".rs", ".mbt")) and "value" in f and "test" not in f:
                cands.append(os.path.join(d, f))
    return sorted(cands, key=len)[0]


res = {}
for t in TRIALS:
    root = os.path.join(WS, t)
    rust = t.startswith("rust")
    clean = "cargo clean" if rust else "moon clean"
    build = "cargo build --release" if rust else "moon build --release"
    check = "cargo check" if rust else "moon check"
    binary = os.path.join(root, "target/release/minisql" if rust else "_build/native/release/build/cmd/main/main.exe")
    r = {}
    runs = []
    for i in range(3):
        run(clean, root)
        dt, rc, out = run(build, root)
        runs.append(dt)
        assert rc == 0, out
    r["clean_release_build_s"] = sorted(runs)[1]
    r["clean_release_build_runs"] = runs
    src = main_source(t, root)
    r["touched_file"] = os.path.relpath(src, root)
    orig = open(src).read()
    inc, chk = [], []
    try:
        for i in range(3):
            open(src, "w").write(orig + f"\n// touch {i}\n")
            dt, rc, out = run(build, root); inc.append(dt)
            open(src, "w").write(orig + f"\n// touch {i}b\n")
            dt, rc, out = run(check, root); chk.append(dt)
    finally:
        open(src, "w").write(orig)
    run(build, root)
    r["incremental_release_build_s"] = sorted(inc)[1]
    r["incremental_check_s"] = sorted(chk)[1]
    r["binary_bytes"] = os.path.getsize(binary)
    subprocess.run(["cp", binary, binary + ".unstripped"])
    stripped = binary + ".stripped"
    subprocess.run(["cp", binary, stripped]); subprocess.run(["strip", stripped])
    r["binary_bytes_stripped"] = os.path.getsize(stripped)
    res[t] = r
    print(t, r, flush=True)
json.dump(res, open(OUT, "w"), indent=1)
