# Writing conformance tests

Tests live in `tests/cases/mNN/<name>.sql`, where `mNN` is the milestone
(`m01` … `m09`) as defined in `spec/SPEC.md` §4. Expected output is produced by
real SQLite (Python's `sqlite3`, version 3.53) using the protocol in SPEC §2:

```
python3 tests/gen_expected.py tests/cases/m02/like_basic.sql   # one file
python3 tests/gen_expected.py tests/cases/m02                  # one milestone
```

Never write `.expected` files by hand. Half of each milestone's cases are
held out as a hidden test suite (chosen by hashing the name), so every file
must be a good test on its own.

## Rules

1. **One topic per file**, named `snake_case` after it (`like_escape.sql`,
   `left_join_nulls.sql`). Aim for 10–40 statements per file. Cover a feature
   from several angles: typical use, NULLs, empty inputs, type/affinity
   mixes, boundaries, and error cases.
2. **Only use features from this milestone and earlier ones.** A test in
   `m03` must not need joins (M5) or CTEs (M7). Check SPEC §4 carefully.
   This matters: agents implement milestones in order and must be able to
   pass all of milestone N with only features ≤ N.
3. **Deterministic order.** Any query that can return more than one row
   needs an `ORDER BY` that fully determines the order (break ties). The
   generator reruns every test with `PRAGMA reverse_unordered_selects=1`
   and rejects it if the output changes. Also avoid ties in `ORDER BY` on
   non-unique keys where the tie order would be visible.
4. **No nondeterminism or out-of-scope features**: no `random()`, no
   `'now'`/`CURRENT_*`, no `PRAGMA` in engine phases, no triggers,
   virtual tables, JSON, `WITHOUT ROWID`, `STRICT`, generated columns,
   `ATTACH`, `EXPLAIN`, `VACUUM`, `sqlite_version()`.
5. **REAL→TEXT conversions** (`CAST(r AS TEXT)`, `r || ''`, `length(r)`,
   `printf('%s', r)`, etc.) only on values with ≤15 significant digits and
   magnitude between 1e-4 and 1e15, where SQLite's conversion matches the
   spec's shortest round-trip format. Printing a REAL directly as a result
   column is always fine.
6. **Error cases are welcome** (the runner only checks that *an* error
   happened), but keep them under about a quarter of the statements, and
   make sure each one fails for the intended reason. A statement that
   errors prints no rows.
7. **Don't depend on unspecified SQLite behavior**: the column names of
   results (not printed), the exact text of error messages, query plans,
   `sqlite_schema.sql` text, or rowids of rows after `VACUUM`.
8. Text output is printed verbatim, so avoid embedded newlines in text
   results unless that is the point of the test. Non-ASCII text (é, 中文,
   emoji) is welcome in string-function tests.
9. Use comments generously to say what each group of statements checks;
   they help the implementing agent and cost nothing.

## Directives

Directives are `-- @name value` lines at the start of a line:

* `-- @timeout 5` — per-phase time limit in seconds (default 10). Use it on
  performance tests.
* `-- @db file` — run against a database file instead of memory. Required
  for M8/M9 tests.
* `-- @phase sqlite` / `-- @phase engine` — starts a phase. Phases run in
  order against the same database file, each as a separate process. A
  `sqlite` phase always runs on real SQLite (to create a file for the engine
  to read, or to verify a file the engine wrote); an `engine` phase runs on
  the implementation under test. PRAGMAs are allowed in sqlite phases
  (`PRAGMA page_size=1024`, `PRAGMA integrity_check`, `PRAGMA
  auto_vacuum=NONE`).

A file without `@phase` lines is a single engine phase on an in-memory
database. That is the form for M1–M7.

### Example: M8 (engine reads a file SQLite wrote)

```sql
-- @db file
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score REAL);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
INSERT INTO t SELECT i, 'name' || i, i * 0.5 FROM n;
-- @phase engine
SELECT count(*), sum(score) FROM t;
SELECT name FROM t WHERE id = 1234;
```

### Example: M9 (engine writes, SQLite verifies)

```sql
-- @db file
-- @phase engine
CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT UNIQUE);
INSERT INTO t VALUES (1, 'x'), (2, 'y');
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM t ORDER BY a;
INSERT INTO t VALUES (3, 'z');
-- @phase engine
SELECT * FROM t ORDER BY a;
```

## Performance tests (M6 and later)

Build big tables without CTEs before M7, e.g. a 10-row digits table
cross-joined with itself:

```sql
CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE big(id INTEGER PRIMARY KEY, k INTEGER, v TEXT);
INSERT INTO big SELECT a.x*10000 + b.x*1000 + c.x*100 + e.x*10 + f.x, (a.x*7919 + f.x*31) % 1000, 'v' || f.x
  FROM d a, d b, d c, d e, d f;
```

Design performance tests so SQLite finishes in well under 0.1 s, a sensible
tree-walking implementation with indexes finishes in about 1 s, and a naive
quadratic plan (full scan per lookup) would take minutes. Set
`-- @timeout 5`.
