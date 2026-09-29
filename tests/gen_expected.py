#!/usr/bin/env python3
"""Generate .expected files for test cases using SQLite as the reference.

For every tests/cases/mNN/*.sql it:
  * runs the case with SQLite playing the engine role,
  * reruns it with PRAGMA reverse_unordered_selects=1 and rejects the case
    if the output changes (result order not fixed by ORDER BY),
  * rejects values the output protocol cannot express (NaN, invalid UTF-8),
  * rejects nondeterministic functions,
  * writes <name>.expected next to the .sql file,
then writes tests/split.json assigning each case to "visible" or "hidden".

Usage: tests/gen_expected.py [--check] [paths or milestone dirs...]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "harness"))
import sqlref  # noqa: E402

CASES = os.path.join(ROOT, "tests", "cases")
SPLIT = os.path.join(ROOT, "tests", "split.json")
HIDDEN_FRACTION = 0.5

BANNED = [
    (re.compile(r"\brandom(blob)?\s*\(", re.I), "random()/randomblob() is nondeterministic"),
    (re.compile(r"'now'|\bcurrent_(date|time|timestamp)\b", re.I), "current time is nondeterministic"),
    (re.compile(r"\b(date|time|datetime|julianday|unixepoch)\s*\(\s*\)|\bstrftime\s*\(\s*'[^']*'\s*\)", re.I),
     "date/time function without a time value uses the current time"),
    (re.compile(r"\bsqlite_version\s*\(|\bsqlite_source_id\s*\(", re.I), "version functions are out of scope"),
    (re.compile(r"^\s*pragma\b", re.I | re.M), "PRAGMA is only allowed in sqlite phases"),
]


def lint(tc: sqlref.TestCase) -> list[str]:
    problems = []
    for p in tc.phases:
        if p.runner != "engine":
            continue
        code = re.sub(r"/\*.*?\*/", "", re.sub(r"--[^\n]*", "", p.script), flags=re.S)
        for rx, why in BANNED:
            if rx.search(code):
                problems.append(why)
    return problems


def _top_level(sql: str) -> str:
    """SQL with comments, string literals and parenthesized groups removed."""
    sql = re.sub(r"/\*.*?\*/", " ", re.sub(r"--[^\n]*", " ", sql), flags=re.S)
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
    prev = None
    while prev != sql:
        prev, sql = sql, re.sub(r"\([^()]*\)", " ", sql)
    return sql


UNORDERED_OK = re.compile(r"^\s*(INSERT|REPLACE|UPDATE|DELETE|VALUES)\b", re.I)


def unordered_multirow(stmt: str, rows: list) -> bool:
    """A query returning several distinct rows without a top-level ORDER BY.
    SQLite often returns compound, GROUP BY and DISTINCT results sorted anyway,
    which the reverse_unordered_selects rerun cannot detect. Row-producing DML
    (RETURNING) and VALUES lists (written order) are exempt."""
    top = _top_level(stmt)
    if len(set(map(repr, rows))) <= 1 or UNORDERED_OK.match(top):
        return False
    if re.search(r"\bVALUES\b", top, re.I) and not re.search(r"\bSELECT\b", top, re.I):
        return False
    return not re.search(r"\bORDER\s+BY\b", top, re.I)


def split_names(milestone: str, names: list[str]) -> tuple[list[str], list[str]]:
    """Exact per-milestone split in hash order, stratified so performance tests
    (perf_*) are divided between visible and hidden too."""
    visible, hidden = [], []
    for group in ([n for n in names if n.startswith("perf_")], [n for n in names if not n.startswith("perf_")]):
        ordered = sorted(group, key=lambda n: hashlib.sha256(f"{milestone}/{n}".encode()).hexdigest())
        k = int(len(ordered) * HIDDEN_FRACTION)
        hidden += ordered[:k]
        visible += ordered[k:]
    return sorted(visible), sorted(hidden)


def process(path: str, check_only: bool) -> tuple[bool, str]:
    try:
        tc = sqlref.parse_test(path)
    except ValueError as e:
        return False, str(e)
    problems = lint(tc)
    if problems:
        return False, "; ".join(sorted(set(problems)))
    unordered: list[str] = []
    hook = lambda stmt, rows: unordered.append(" ".join(stmt.split())[:120]) if unordered_multirow(stmt, rows) else None
    try:
        out, err = sqlref.run_case(tc, None, stmt_hook=hook)
        rev, _ = sqlref.run_case(tc, None, reverse_unordered=True)
    except sqlref.UnformattableValue as e:
        return False, f"unformattable value: {e}"
    if err:
        return False, err
    if out != rev:
        return False, "nondeterministic row order (add ORDER BY)"
    if unordered:
        return False, f"multi-row query without top-level ORDER BY: {unordered[0]}"
    n_stmt = sum(len(sqlref.split_statements(p.script)) for p in tc.phases)
    n_err = out.count("\nError: ") + (1 if out.startswith("Error: ") else 0)
    exp_path = path[: -len(".sql")] + ".expected"
    if check_only:
        if not os.path.exists(exp_path) or open(exp_path, encoding="utf-8").read() != out:
            return False, "expected output is stale"
    else:
        with open(exp_path, "w", encoding="utf-8") as f:
            f.write(out)
    note = f"{n_stmt} stmts, {out.count(chr(10))} lines, {n_err} errors"
    if n_stmt and n_err / n_stmt > 0.5:
        note += "  [warning: more than half the statements fail]"
    return True, note


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--check", action="store_true", help="verify .expected files are current")
    ap.add_argument("-q", "--quiet", action="store_true")
    args = ap.parse_args()
    if sqlref.sqlite3.sqlite_version != sqlref.REFERENCE_SQLITE:
        raise SystemExit(f"Python's sqlite3 is {sqlref.sqlite3.sqlite_version}, "
                         f"but expected outputs must be generated with {sqlref.REFERENCE_SQLITE}")

    targets = args.paths or [os.path.join(CASES, d) for d in sorted(os.listdir(CASES))]
    files: list[str] = []
    for t in targets:
        if os.path.isdir(t):
            files += [os.path.join(t, f) for f in sorted(os.listdir(t)) if f.endswith(".sql")]
        else:
            files.append(t)

    bad = 0
    for f in files:
        ok, msg = process(os.path.abspath(f), args.check)
        if not ok:
            bad += 1
            print(f"FAIL {os.path.relpath(f, ROOT)}: {msg}")
        elif not args.quiet:
            print(f"ok   {os.path.relpath(f, ROOT)}: {msg}")

    if not args.paths:
        # Rebuild the visible/hidden split from every case on disk.
        split: dict[str, dict[str, list[str]]] = {}
        for m in sorted(os.listdir(CASES)):
            d = os.path.join(CASES, m)
            if not os.path.isdir(d):
                continue
            names = sorted(f[:-4] for f in os.listdir(d) if f.endswith(".sql"))
            vis, hid = split_names(m, names)
            split[m] = {"visible": vis, "hidden": hid}
        with open(SPLIT, "w") as fh:
            json.dump(split, fh, indent=1)
        total = sum(len(v["visible"]) + len(v["hidden"]) for v in split.values())
        print(f"split.json: {total} cases")
        for m, v in split.items():
            print(f"  {m}: {len(v['visible'])} visible, {len(v['hidden'])} hidden")

    print(f"{len(files) - bad}/{len(files)} cases ok")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
