#!/usr/bin/env python3
"""Conformance test runner for minisql.

Builds the engine (unless --no-build), runs every test case under tests/,
and compares output with the .expected file. Error messages are not
compared: any line starting with "Error:" matches any other such line.

Examples:
  python3 tools/run_tests.py                 # all milestones present
  python3 tools/run_tests.py --upto 3        # milestones 1..3
  python3 tools/run_tests.py -m 2            # milestone 2 only
  python3 tools/run_tests.py -k like         # cases whose name contains "like"
  python3 tools/run_tests.py -k m02/like_escape -v   # full diff for one case
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import difflib
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sqlref  # noqa: E402


def load_lang(root: str, path: str | None = None) -> dict:
    with open(path or os.path.join(root, "tools", "lang.json")) as f:
        return json.load(f)


def build(root: str, lang: dict) -> bool:
    t0 = time.time()
    r = subprocess.run(lang["build"], shell=True, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        text = r.stdout.decode("utf-8", errors="replace").rstrip().split("\n")
        print("BUILD FAILED (last 60 lines):")
        print("\n".join(text[-60:]))
        return False
    print(f"build ok ({time.time() - t0:.1f}s)")
    return True


def collect(tests_dir: str, ms: set[int] | None, pattern: str | None) -> list[tuple[str, str]]:
    cases = []
    for m in sorted(os.listdir(tests_dir)):
        d = os.path.join(tests_dir, m)
        if not (os.path.isdir(d) and m.startswith("m") and m[1:].isdigit()):
            continue
        if ms is not None and int(m[1:]) not in ms:
            continue
        for f in sorted(os.listdir(d)):
            if f.endswith(".sql"):
                key = f"{m}/{f[:-4]}"
                if pattern and pattern not in key:
                    continue
                cases.append((key, os.path.join(d, f)))
    return cases


def run_one(key: str, path: str, engine: list[str]) -> dict:
    tc = sqlref.parse_test(path)
    with open(path[: -len(".sql")] + ".expected", encoding="utf-8") as f:
        expected = f.read()
    t0 = time.time()
    try:
        actual, err = sqlref.run_case(tc, engine)
    except sqlref.UnformattableValue as e:
        # e.g. the engine stored invalid UTF-8 that a later sqlite phase reads back
        actual, err = "", f"sqlite phase could not format a value: {e}"
    dt = time.time() - t0
    exp_n, act_n = sqlref.normalize(expected), sqlref.normalize(actual)
    passed = err is None and exp_n == act_n
    ratio = 1.0 if passed else difflib.SequenceMatcher(None, exp_n.split("\n"), act_n.split("\n")).ratio()
    return {"case": key, "passed": passed, "error": err, "seconds": round(dt, 3),
            "similarity": round(ratio, 4), "expected": exp_n, "actual": act_n}


def show_diff(r: dict, limit: int | None) -> None:
    if r["error"]:
        print(f"    {r['error'].strip()}")
    diff = list(difflib.unified_diff(r["expected"].split("\n"), r["actual"].split("\n"),
                                     "expected", "actual", lineterm="", n=2))
    if limit is not None and len(diff) > limit:
        diff = diff[:limit] + [f"... ({len(diff) - limit} more diff lines; rerun with -k {r['case']} -v)"]
    for line in diff:
        print("    " + line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-m", "--milestone", type=int, action="append", help="only this milestone (repeatable)")
    ap.add_argument("--upto", type=int, help="milestones 1..N")
    ap.add_argument("-k", dest="pattern", help="substring filter on 'mNN/name'")
    ap.add_argument("-v", "--verbose", action="store_true", help="full diff for every failure")
    ap.add_argument("--show", type=int, default=5, help="failures to show a short diff for (default 5)")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--root", default=os.path.dirname(HERE), help=argparse.SUPPRESS)
    ap.add_argument("--tests-dir", help=argparse.SUPPRESS)
    ap.add_argument("--json", help=argparse.SUPPRESS)
    ap.add_argument("--lang-json", help=argparse.SUPPRESS)
    args = ap.parse_args()

    if sqlref.sqlite3.sqlite_version != sqlref.REFERENCE_SQLITE:
        print(f"warning: Python's sqlite3 is {sqlref.sqlite3.sqlite_version}; expected outputs "
              f"were generated with {sqlref.REFERENCE_SQLITE}")
    root = os.path.abspath(args.root)
    lang = load_lang(root, args.lang_json)
    if not args.no_build and not build(root, lang):
        if args.json:
            with open(args.json, "w") as f:
                json.dump({"build_ok": False, "results": []}, f)
        return 2
    engine = [os.path.join(root, lang["binary"])]
    if not os.path.exists(engine[0]):
        print(f"engine binary not found: {lang['binary']}")
        return 2

    ms = set(args.milestone or [])
    if args.upto:
        ms |= set(range(1, args.upto + 1))
    tests_dir = args.tests_dir or os.path.join(root, "tests")
    cases = collect(tests_dir, ms or None, args.pattern)
    if not cases:
        print("no matching test cases")
        return 2

    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        results = list(ex.map(lambda c: run_one(c[0], c[1], engine), cases))

    by_m: dict[str, list[dict]] = {}
    for r in results:
        by_m.setdefault(r["case"].split("/")[0], []).append(r)
    failures = [r for r in results if not r["passed"]]
    shown = 0
    for r in failures:
        if args.verbose or shown < args.show:
            print(f"FAIL {r['case']}")
            show_diff(r, None if args.verbose else 12)
            shown += 1
    if failures and not args.verbose and len(failures) > shown:
        rest = [r["case"] for r in failures[shown:]]
        print(f"other failures ({len(rest)}): " + " ".join(rest))
    for m, rs in sorted(by_m.items()):
        p = sum(r["passed"] for r in rs)
        print(f"{m}: {p}/{len(rs)} passed")
    total = sum(r["passed"] for r in results)
    print(f"TOTAL: {total}/{len(results)} passed")

    if args.json:
        slim = [{k: v for k, v in r.items() if k not in ("expected", "actual")} for r in results]
        with open(args.json, "w") as f:
            json.dump({"build_ok": True, "results": slim}, f, indent=1)
    return 0 if total == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
