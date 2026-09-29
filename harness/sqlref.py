"""Shared test-format logic: statement splitting, value formatting, test-file
parsing, and the SQLite reference executor.

Used by the expected-output generator (tests/gen_expected.py) and by the
conformance runner that is copied into every workspace (run_tests.py).
"""

from __future__ import annotations

import math
import os
import re
import sqlite3
import subprocess
import tempfile
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Statement splitting (SPEC.md §2.2)
# ---------------------------------------------------------------------------


def split_statements(script: str) -> list[str]:
    """Split a script on ';' outside quotes and comments.

    Comments are kept inside the statement text. Statements that contain
    only whitespace and comments are dropped.
    """
    out: list[str] = []
    buf: list[str] = []
    i, n = 0, len(script)
    while i < n:
        c = script[i]
        if c in "'\"`":
            j = i + 1
            while j < n:
                if script[j] == c:
                    if j + 1 < n and script[j + 1] == c:
                        j += 2
                        continue
                    break
                j += 1
            buf.append(script[i : j + 1])
            i = j + 1
        elif c == "[":
            j = script.find("]", i + 1)
            j = n - 1 if j < 0 else j
            buf.append(script[i : j + 1])
            i = j + 1
        elif script.startswith("--", i):
            j = script.find("\n", i)
            j = n if j < 0 else j
            buf.append(script[i:j])
            i = j
        elif script.startswith("/*", i):
            j = script.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(script[i:j])
            i = j
        elif c == ";":
            out.append("".join(buf))
            buf = []
            i += 1
        else:
            buf.append(c)
            i += 1
    out.append("".join(buf))
    return [s.strip() for s in out if not _is_blank(s)]


def _is_blank(stmt: str) -> bool:
    s = re.sub(r"--[^\n]*", "", stmt)
    s = re.sub(r"/\*.*?(\*/|$)", "", s, flags=re.S)
    return s.strip() == ""


# ---------------------------------------------------------------------------
# Value formatting (SPEC.md §2.3)
# ---------------------------------------------------------------------------


class UnformattableValue(Exception):
    pass


def format_real(x: float) -> str:
    if math.isnan(x):
        raise UnformattableValue("NaN")
    if math.isinf(x):
        return "Inf" if x > 0 else "-Inf"
    if x == 0.0:
        return "0.0"
    r = repr(x)  # shortest round-trip digits; scientific iff exp < -4 or exp >= 16
    if "e" in r:
        mant, exp = r.split("e")
        if "." not in mant:
            mant += ".0"
        sign = exp[0] if exp[0] in "+-" else "+"
        digits = exp.lstrip("+-").rjust(2, "0")
        return f"{mant}e{sign}{digits}"
    if "." not in r:
        r += ".0"
    return r


def format_value(v) -> str:
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return format_real(v)
    if isinstance(v, (bytes, bytearray, memoryview)):
        return "X'" + bytes(v).hex().upper() + "'"
    if isinstance(v, str):
        return v
    raise UnformattableValue(repr(v))


def format_row(row) -> str:
    return "|".join(format_value(v) for v in row)


# ---------------------------------------------------------------------------
# Test files (.sql with optional directives)
# ---------------------------------------------------------------------------

# SQLite version that generated the .expected files (sqlite phases also run on it).
REFERENCE_SQLITE = "3.53.3"

DIRECTIVE = re.compile(r"^--\s*@(\w+)\s*(.*?)\s*$")


@dataclass
class Phase:
    runner: str  # "engine" or "sqlite"
    script: str


@dataclass
class TestCase:
    path: str
    name: str
    uses_file: bool = False
    timeout: float = 10.0
    phases: list[Phase] = field(default_factory=list)


def parse_test(path: str) -> TestCase:
    name = os.path.splitext(os.path.basename(path))[0]
    tc = TestCase(path=path, name=name)
    cur_runner = "engine"
    cur: list[str] = []
    started = False
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    for line in lines:
        m = DIRECTIVE.match(line)
        if m:
            key, arg = m.group(1), m.group(2)
            if key == "db":
                if arg != "file":
                    raise ValueError(f"{path}: unknown @db {arg!r}")
                tc.uses_file = True
                continue
            if key == "timeout":
                tc.timeout = float(arg)
                continue
            if key == "phase":
                if arg not in ("engine", "sqlite"):
                    raise ValueError(f"{path}: unknown @phase {arg!r}")
                if started:
                    tc.phases.append(Phase(cur_runner, "\n".join(cur)))
                cur_runner, cur, started = arg, [], True
                continue
            if key in ("description", "tags"):
                continue
            raise ValueError(f"{path}: unknown directive @{key}")
        cur.append(line)
    tc.phases.append(Phase(cur_runner, "\n".join(cur)))
    if any(p.runner == "sqlite" for p in tc.phases) and not tc.uses_file:
        raise ValueError(f"{path}: sqlite phases require '-- @db file'")
    return tc


def phase_header(i: int, p: Phase) -> str:
    return f"===== phase {i + 1} ({p.runner}) =====\n"


# ---------------------------------------------------------------------------
# Reference execution with SQLite
# ---------------------------------------------------------------------------


def _strict_text(b: bytes) -> str:
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError as e:
        raise UnformattableValue(f"invalid UTF-8 text value {b!r}") from e


def run_sqlite_script(script: str, db_path: str | None, reverse_unordered: bool = False,
                      stmt_hook=None) -> str:
    """Execute a script with SQLite using the engine output protocol."""
    conn = sqlite3.connect(db_path or ":memory:", isolation_level=None)
    conn.text_factory = _strict_text
    try:
        if reverse_unordered:
            conn.execute("PRAGMA reverse_unordered_selects=1")
        out: list[str] = []
        for stmt in split_statements(script):
            try:
                rows = conn.execute(stmt).fetchall()
            except sqlite3.Error as e:
                msg = str(e).replace("\n", " ")
                out.append(f"Error: {msg}\n")
                continue
            if stmt_hook:
                stmt_hook(stmt, rows)
            for row in rows:
                out.append(format_row(row) + "\n")
        return "".join(out)
    finally:
        if conn.in_transaction:
            # An engine process that exits mid-transaction discards it.
            conn.rollback()
        conn.close()


def run_case(tc: TestCase, engine_cmd: list[str] | None, reverse_unordered: bool = False, stmt_hook=None):
    """Run a test case. engine_cmd=None means SQLite plays the engine role
    (used to generate expected output). Returns (output, error_or_None)."""
    tmpdir = tempfile.mkdtemp(prefix="minisql-")
    db = os.path.join(tmpdir, "test.db") if tc.uses_file else None
    out: list[str] = []
    multi = len(tc.phases) > 1
    try:
        for i, p in enumerate(tc.phases):
            if multi:
                out.append(phase_header(i, p))
            if p.runner == "sqlite" or engine_cmd is None:
                hook = stmt_hook if p.runner == "engine" else None
                out.append(run_sqlite_script(p.script, db, reverse_unordered, hook))
                continue
            cmd = list(engine_cmd) + ([db] if db else [])
            try:
                r = subprocess.run(
                    cmd,
                    input=p.script.encode("utf-8"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=tc.timeout,
                )
            except subprocess.TimeoutExpired:
                return "".join(out), f"timeout after {tc.timeout}s in phase {i + 1}"
            out.append(r.stdout.decode("utf-8", errors="replace"))
            if r.returncode != 0:
                tail = r.stderr.decode("utf-8", errors="replace")[-400:]
                return "".join(out), f"exit code {r.returncode} in phase {i + 1}: {tail}"
        return "".join(out), None
    finally:
        for f in os.listdir(tmpdir):
            os.remove(os.path.join(tmpdir, f))
        os.rmdir(tmpdir)


_ERROR_LINE = re.compile(r"^Error:.*$", re.M)


def normalize(output: str) -> str:
    """Error messages are not compared, only the fact that an error occurred."""
    return _ERROR_LINE.sub("Error", output)
