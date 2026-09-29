#!/usr/bin/env python3
"""A stand-in engine backed by SQLite, used to validate the harness itself.
Every test must pass against it: `fake_engine.py [DBFILE] < script.sql`."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sqlref  # noqa: E402

db = sys.argv[1] if len(sys.argv) > 1 else None
sys.stdout.write(sqlref.run_sqlite_script(sys.stdin.read(), db))
