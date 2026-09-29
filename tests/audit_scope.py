#!/usr/bin/env python3
"""Heuristic check that tests only use features of their milestone or earlier.

Scans engine phases (comments and string literals removed) for markers of
features introduced in later milestones (SPEC.md §4) and prints suspects.
It is a lint, not a parser: review each hit by hand.
"""

from __future__ import annotations

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "harness"))
import sqlref  # noqa: E402

F = lambda *names: r"\b(" + "|".join(names) + r")\s*\("  # function call

MARKERS: list[tuple[int, str, str]] = [
    (2, r"\bCASE\b", "CASE"), (2, r"\bCAST\s*\(", "CAST"), (2, r"\bBETWEEN\b", "BETWEEN"),
    (2, r"\bIN\s*\(", "IN (...)"), (2, r"\b(LIKE|GLOB)\b", "LIKE/GLOB"), (2, r"\bCOLLATE\b", "COLLATE"),
    (2, r"\bDISTINCT\s+FROM\b", "IS DISTINCT FROM"), (2, r"<<|>>|~|(?<![|])&", "bitwise op"),
    (2, F("abs", "char", "coalesce", "concat", "concat_ws", "format", "printf", "glob", "hex", "ifnull",
          "iif", "if", "instr", "length", "like", "likelihood", "likely", "lower", "ltrim", "nullif",
          "octet_length", "quote", "replace", "round", "rtrim", "sign", "substr", "substring", "trim",
          "unhex", "unicode", "unlikely", "upper", "zeroblob", "sqrt", "pow", "power", "floor", "ceil",
          "ceiling", "exp", "ln", "log", "log10", "log2", "sin", "cos", "tan", "pi", "mod", "trunc",
          "degrees", "radians", "atan2", "acos", "asin", "atan", "sinh", "cosh", "tanh", "acosh", "asinh",
          "atanh"), "scalar function"),
    (3, r"\bLIMIT\b", "LIMIT"), (3, r"\bSELECT\s+DISTINCT\b", "SELECT DISTINCT"), (3, r"\bUPDATE\b", "UPDATE"),
    (3, r"\bDELETE\b", "DELETE"), (3, r"\bREPLACE\s+INTO\b|\bOR\s+(REPLACE|IGNORE|ABORT|FAIL|ROLLBACK)\b", "conflict clause"),
    (3, r"\bON\s+CONFLICT\b", "ON CONFLICT"), (3, r"\bRETURNING\b", "RETURNING"), (3, r"\bNULLS\s+(FIRST|LAST)\b", "NULLS FIRST/LAST"),
    (3, r"\bDEFAULT\s+VALUES\b", "DEFAULT VALUES"), (3, r"\bINSERT\b[^;]*?\bSELECT\b", "INSERT ... SELECT"),
    (3, F("changes", "total_changes", "last_insert_rowid"), "changes()"), (3, r"\b(rowid|oid|_rowid_)\b", "rowid"),
    (4, F("count", "sum", "total", "avg", "group_concat", "string_agg"), "aggregate"),
    (4, r"\bGROUP\s+BY\b", "GROUP BY"), (4, r"\bHAVING\b", "HAVING"), (4, r"\bFILTER\s*\(", "FILTER"),
    (4, F("date", "time", "datetime", "julianday", "unixepoch", "strftime", "timediff"), "date/time"),
    (5, r"\bJOIN\b", "JOIN"), (5, r"\b(UNION|INTERSECT|EXCEPT)\b", "compound"), (5, r"\bEXISTS\s*\(", "EXISTS"),
    (5, r"\(\s*SELECT\b", "subquery"), (5, r"\bFROM\s+\w+(\s+(AS\s+)?\w+)?\s*,", "comma join"),
    (5, r"(^|;|\(|\bFROM)\s*VALUES\b", "VALUES as query"),
    (6, r"\bINDEX\b", "INDEX"), (6, r"\bVIEW\b", "VIEW"), (6, r"\bALTER\b", "ALTER"),
    (6, r"\b(BEGIN|COMMIT|SAVEPOINT|RELEASE)\b|\bROLLBACK\b(?!\s*\))", "transaction"),
    (6, r"\bsqlite_(schema|master)\b", "sqlite_schema"),
    (7, r"^\s*WITH\b|\bWITH\s+RECURSIVE\b|\(\s*WITH\b", "WITH"), (7, r"\bOVER\b", "OVER"), (7, r"\bWINDOW\b", "WINDOW"),
]
COMPILED = [(m, re.compile(rx, re.I | re.M), label) for m, rx, label in MARKERS]


def strip(sql: str) -> str:
    sql = re.sub(r"--[^\n]*", "", sql)
    sql = re.sub(r"/\*.*?\*/", "", sql, flags=re.S)
    sql = re.sub(r"'(?:[^']|'')*'", "''", sql)
    return sql


def main() -> int:
    cases = os.path.join(ROOT, "tests", "cases")
    hits = 0
    for m in sorted(os.listdir(cases)):
        if not re.fullmatch(r"m\d\d", m):
            continue
        level = int(m[1:])
        for f in sorted(os.listdir(os.path.join(cases, m))):
            if not f.endswith(".sql"):
                continue
            tc = sqlref.parse_test(os.path.join(cases, m, f))
            for p in tc.phases:
                if p.runner != "engine":
                    continue
                for stmt in sqlref.split_statements(p.script):
                    code = strip(stmt)
                    for need, rx, label in COMPILED:
                        if need > level and rx.search(code):
                            hits += 1
                            one = " ".join(stmt.split())[:150]
                            print(f"{m}/{f}: needs M{need} ({label}): {one}")
    print(f"{hits} suspect statements")
    return 0


if __name__ == "__main__":
    sys.exit(main())
