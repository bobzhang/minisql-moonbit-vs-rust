# minisql — specification

You are building **minisql**, a SQL database engine compatible with SQLite
(reference version: SQLite 3.53). It is a command-line program that executes a
SQL script read from standard input and prints query results to standard output.

The work is split into nine milestones (§4). Each milestone has a conformance
test suite under `tests/mNN/`. Expected outputs were produced by real SQLite, so
**SQLite's behavior is the ground truth** for everything this document leaves
unstated: type affinity, NULL handling, comparison rules, function results,
integer overflow, and so on. Where this document and SQLite disagree, this
document wins (that only happens in the output protocol, §2).

## 1. Ground rules

1. Use only the language's standard library (Rust: `std`; MoonBit:
   `moonbitlang/core`). No third-party packages, no C code, no FFI, no
   linking or embedding SQLite, no spawning processes.
2. All process I/O goes through the provided `io` module (stdin, stdout,
   arguments, whole-file read/write). Do not modify it.
3. Do not special-case test names or test contents. A hidden test suite with
   different cases covers the same features.
4. Performance: each test phase has a time limit (default 10 s, some tests
   set less). Tests in milestone 6 and later need indexes and reasonable
   algorithms (no quadratic scans where SQLite would use an index).

## 2. Program interface and output protocol

### 2.1 Invocation

```
minisql [DBFILE] < script.sql
```

* Without `DBFILE`, the database is in memory and starts empty.
* With `DBFILE` (milestones 8–9), the database is that file, in the SQLite 3
  file format (§5). If the file does not exist, start with an empty database
  and create the file.
* Exit with status 0 after the whole script has run, even if statements
  failed. A crash or non-zero exit fails the test.

### 2.2 Splitting the script into statements

The script is split on `;` characters that are not inside a string literal
(`'...'`), a quoted identifier (`"..."`, `` `...` ``, `[...]`), a `--` line
comment, or a `/* */` block comment. Doubled quote characters inside a quoted
token (`'it''s'`) do not end it. Pieces that contain only whitespace and
comments are ignored. The text after the last `;` is a statement if it
contains anything other than whitespace and comments.

Statements execute in order. An error in one statement does not stop the
script.

### 2.3 Output

For each statement, in order:

* If it succeeds and returns rows (a `SELECT`, `VALUES`, a `WITH ... SELECT`,
  or any statement with `RETURNING`), print one line per row: the column
  values joined by `|`, followed by `\n`. No header line. A statement that
  returns no rows prints nothing.
* If it succeeds and returns no rows (DDL, DML without `RETURNING`,
  transaction control), print nothing.
* If it fails at any point (parse error, unknown table, constraint violation,
  runtime error), print exactly one line starting with `Error:` followed by
  a message, and **no rows from that statement**. Buffer a statement's rows
  until it completes. Messages are not compared, so any text works, but
  SQLite's wording is recommended.

Values are printed as:

| Storage class | Printed as |
|---|---|
| NULL | `NULL` |
| INTEGER | decimal, with `-` if negative: `42`, `-7`, `9223372036854775807` |
| REAL | see below |
| TEXT | the text, verbatim (UTF-8) |
| BLOB | `X'` + uppercase hex of the bytes + `'`, e.g. `X'00FF'`; empty blob `X''` |

**REAL formatting.** Take the shortest decimal digit string that
round-trips to the same 64-bit double (what Rust's `{}`/`{:e}`, Python's
`repr`, or JavaScript's `String(x)` produce). Let `E` be the decimal exponent
of its first significant digit (so `x = d.ddd × 10^E`).

* If `-5 < E < 16`: fixed notation. Always include a fractional part: `1.0`,
  `100.0`, `0.25`, `123456.789`, `0.0001`, `1000000000000000.0`.
* Otherwise: scientific notation `<mantissa>e<sign><exponent>` where the
  mantissa always contains a `.` (`1.0`, `2.5`, `1.2345`), the sign is `+` or
  `-`, and the exponent has at least two digits: `1.0e+16`, `2.5e-07`,
  `1.0e-05`, `1.7976931348623157e+308`, `5.0e-324`.
* Positive and negative zero print as `0.0`.
* Infinities print as `Inf` and `-Inf`. (SQLite never produces NaN; it
  becomes NULL.)

Converting a REAL to TEXT inside SQL (`CAST(x AS TEXT)`, `x || ''`, text
functions applied to reals) uses the same format. SQLite itself sometimes
emits a 17th digit in those conversions; tests avoid those values.

## 3. SQL language

SQL keywords and identifiers are case-insensitive (identifiers keep their
original spelling). Identifiers may be quoted with `"..."`, `` `...` `` or
`[...]`. String literals use `'...'`. As in SQLite, a double-quoted token
that does not resolve to a column is treated as a string literal. Blob
literals are `X'hex'`. Numeric literals include integers, decimals, exponents
(`1e10`, `.5`, `5.`) and hex integers (`0x1F`). Comments: `-- ...` and
`/* ... */`.

Value semantics follow SQLite: dynamic typing with the five storage classes,
column type affinity (INTEGER, REAL, NUMERIC, TEXT, BLOB, determined from the
declared type name by SQLite's rules), affinity applied on storage and in
comparisons, three-valued logic, 64-bit integer arithmetic that switches to
REAL on overflow (except where SQLite raises "integer overflow"), division
by zero yielding NULL, and SQLite's cross-class sort order
(NULL < INTEGER/REAL < TEXT < BLOB).

Features are listed per milestone in §4. Features not listed anywhere
(triggers, virtual tables, `ATTACH`, `PRAGMA`, `EXPLAIN`, `ANALYZE`,
`VACUUM`, `REINDEX`, JSON functions, `WITHOUT ROWID` tables, generated
columns, `STRICT` tables, foreign-key enforcement, `random()`, the current
date/time) are not tested. Parsing `REFERENCES`/`FOREIGN KEY` clauses is
required (they appear in schemas) but they are not enforced.

## 4. Milestones

Tests for milestone N may use features of all milestones ≤ N.

### M1 — Core pipeline

* Program interface, statement splitting and output protocol (§2).
* Lexer covering the whole SQL surface described in this document.
* `CREATE TABLE [IF NOT EXISTS] name (column-defs)`: column names with
  optional declared types (any type name, including forms like
  `VARCHAR(20)` and `DECIMAL(10, 2)` and multi-word names); constraint
  clauses must parse (enforcement starts in M3). `DROP TABLE [IF EXISTS]`.
* `INSERT INTO t [(cols)] VALUES (...), (...)`, with type affinity applied on
  storage.
* `SELECT [ALL] result-columns [FROM table [AS alias]] [WHERE expr]
  [ORDER BY expr [ASC|DESC], ...]`: `*`, `table.*`, expressions with
  `[AS] alias`, `SELECT` without `FROM`. `ORDER BY` here means plain
  expressions with SQLite's default ordering (NULLs first ascending,
  cross-class order, BINARY collation); M3 adds the rest, including
  integer constants as result-column numbers. Using a result alias inside
  `WHERE` (which SQLite allows) is not tested.
* Expressions: literals (integer, real, string, blob, NULL, `TRUE`/`FALSE`),
  column references (`col`, `table.col`), unary `-`/`+`, `+ - * / %`, `||`,
  `= == != <> < <= > >=`, `AND OR NOT`, `IS NULL`, `IS NOT NULL`, `ISNULL`,
  `NOTNULL`, `NOT NULL` (postfix), parentheses, SQLite operator precedence.
* `typeof(x)`.
* Errors: syntax errors, no such table, no such column, table already exists,
  duplicate column name, wrong number of values in `INSERT`.

### M2 — Expressions and scalar functions

* `CASE` (both forms), `CAST(x AS type)`, `IS [NOT]`, `IS [NOT] DISTINCT FROM`,
  `[NOT] BETWEEN`, `[NOT] IN (list)`, `[NOT] LIKE ... [ESCAPE ...]`,
  `[NOT] GLOB`, bitwise `& | ~ << >>`, `COLLATE` operator.
* Collations `BINARY`, `NOCASE`, `RTRIM`, including declared column
  collations (`name TEXT COLLATE NOCASE`) and SQLite's rules for which
  collation a comparison uses.
* Comparison affinity rules between columns, literals and expressions.
* Scalar functions: `abs`, `char`, `coalesce`, `concat`, `concat_ws`,
  `format`/`printf` (flags, width, precision; conversions `d i u f e E g G
  x X o s q Q w c %`; like SQLite, ties round away from zero; tests use at
  most 15 significant digits), `glob`, `hex`, `ifnull`, `iif`/`if` (2 or 3 arguments), `instr`,
  `length`, `like`, `likelihood`, `likely`, `lower`, `ltrim`, `max`/`min`
  (scalar, 2+ arguments), `nullif`, `octet_length`, `quote`, `replace`,
  `round`, `rtrim`, `sign`, `substr`/`substring`, `trim`, `unhex`,
  `unicode`, `unlikely`, `upper`, `zeroblob`.
* Math functions: `acos acosh asin asinh atan atan2 atanh ceil ceiling cos
  cosh degrees exp floor ln log log10 log2 mod pi pow power radians sin
  sinh sqrt tan tanh trunc`. Tests round inexact results (e.g.
  `round(sin(x), 12)`), so any correctly rounded libm is fine.
* Errors: wrong number of arguments, no such function.

### M3 — Query shaping, DML and constraints

* Full `ORDER BY` (result-column aliases, ordinals, `NULLS FIRST`/`NULLS
  LAST`, `COLLATE`, declared column collations), `LIMIT n [OFFSET m]`,
  `LIMIT m, n`, `SELECT DISTINCT`.
* `UPDATE t SET ... [WHERE ...]`, `DELETE FROM t [WHERE ...]`,
  `INSERT INTO t [(cols)] SELECT ...`, `INSERT INTO t DEFAULT VALUES`,
  `REPLACE INTO`, `INSERT OR {REPLACE|IGNORE|ABORT|FAIL|ROLLBACK}`,
  `UPDATE OR ...`, upsert (`ON CONFLICT [(cols)] DO NOTHING | DO UPDATE SET
  ... [WHERE ...]`, `excluded.col`), `RETURNING` on INSERT/UPDATE/DELETE.
  Tests only depend on `RETURNING` row order for multi-row `INSERT ...
  VALUES` (row order) and for `UPDATE`/`DELETE` on tables without indexes
  (rowid order).
* Constraints: `NOT NULL`, `UNIQUE` (column and table level, multi-column),
  `PRIMARY KEY` (column and table level), `CHECK`, `DEFAULT` (literal,
  signed number, `(expr)`), conflict clauses on constraints (`ON CONFLICT
  ...`), `COLLATE` in column definitions.
* Rowids: `rowid`/`oid`/`_rowid_`, `INTEGER PRIMARY KEY` as a rowid alias,
  `AUTOINCREMENT`, rowid assignment rules (max+1).
* A failing statement leaves no partial effects (statement atomicity).
* `changes()`, `total_changes()`, `last_insert_rowid()`.

### M4 — Aggregation and date/time

* Aggregates: `count(*)`, `count(x)`, `sum`, `total`, `avg`, `min`, `max`,
  `group_concat(x [, sep])`, `string_agg(x, sep)`; `DISTINCT` inside
  aggregates; `FILTER (WHERE ...)`; `ORDER BY` inside aggregate arguments.
* `GROUP BY` (expressions, aliases, ordinals), `HAVING`, aggregates without
  `GROUP BY`, SQLite's bare-column rule (a bare column in a `min()`/`max()`
  query takes the value from the row that produced the min/max).
* Integer overflow in `sum` raises an error; `total` never does.
* Date and time functions with explicit time values (never `'now'`):
  `date`, `time`, `datetime`, `julianday`, `unixepoch`, `strftime`,
  `timediff`; input formats (ISO-8601 variants, Julian day numbers, unix
  timestamps with `'unixepoch'`; calls without a time value are not
  tested); modifiers `±N days/hours/minutes/seconds/
  months/years`, `±HH:MM[:SS]`, `start of month/year/day`, `weekday N`,
  `unixepoch`, `julianday`, `auto`, `subsec`/`subsecond`, `ceiling`,
  `floor` (`utc` and `localtime` are not tested).

### M5 — Joins, subqueries and compound queries

* Joins: comma, `CROSS JOIN`, `[INNER] JOIN`, `LEFT [OUTER]`, `RIGHT
  [OUTER]`, `FULL [OUTER]`, `NATURAL`, `ON`, `USING (cols)`; self-joins;
  multi-way joins; column resolution and ambiguity rules (ambiguous column
  name errors); `*` expansion with
  `USING`/`NATURAL`.
* Subqueries: scalar subqueries (first row, NULL if empty), `[NOT] IN
  (SELECT ...)`, `[NOT] EXISTS`, correlated subqueries anywhere an
  expression is allowed, subqueries in `FROM` with aliases.
* Compound queries: `UNION`, `UNION ALL`, `INTERSECT`, `EXCEPT`, with
  `ORDER BY`/`LIMIT` applying to the whole compound.
* `VALUES (...), (...)` as a query and as a `FROM` source.

### M6 — Schema, indexes and transactions

* `CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON t (col-or-expr [COLLATE c]
  [ASC|DESC], ...) [WHERE expr]` (partial and expression indexes),
  `DROP INDEX [IF EXISTS]`. Unique indexes enforce uniqueness.
* `CREATE VIEW [IF NOT EXISTS] name [(cols)] AS select`, `DROP VIEW
  [IF EXISTS]`; views are queryable like tables (read-only).
* `ALTER TABLE t RENAME TO u`, `ALTER TABLE t RENAME [COLUMN] a TO b`,
  `ALTER TABLE t ADD [COLUMN] def`, `ALTER TABLE t DROP [COLUMN] c`.
* `sqlite_schema` (alias `sqlite_master`) is queryable; tests only select
  its `type`, `name` and `tbl_name` columns.
* Transactions: `BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION]`,
  `COMMIT`/`END [TRANSACTION]`, `ROLLBACK [TRANSACTION]`, `SAVEPOINT name`, `RELEASE [SAVEPOINT] name`,
  `ROLLBACK [TRANSACTION] TO [SAVEPOINT] name`; errors for nested `BEGIN`
  or `COMMIT` without a transaction; rollback restores schema changes too.
* Performance: queries over tens of thousands of rows must use indexes for
  equality and range lookups, joins and `ORDER BY` where SQLite would.

### M7 — CTEs and window functions

* `WITH [RECURSIVE] name [(cols)] AS [NOT] [MATERIALIZED] (select), ...`
  before `SELECT`, `INSERT`, `UPDATE` and `DELETE`; recursive CTEs with
  `UNION` and `UNION ALL`, including `ORDER BY`/`LIMIT` in the recursive
  part. Tests bound recursion inside the CTE (a `WHERE` or `LIMIT` there);
  an outer `LIMIT` on an infinite recursive CTE is not tested.
* Window functions: `row_number`, `rank`, `dense_rank`, `percent_rank`,
  `cume_dist`, `ntile`, `lag`, `lead`, `first_value`, `last_value`,
  `nth_value`, and every aggregate from M4 used with `OVER` (as in SQLite,
  `DISTINCT` and `ORDER BY` inside the arguments of a window aggregate are
  errors).
* `OVER (PARTITION BY ... ORDER BY ... frame)`, named windows (`WINDOW w AS
  (...)`, `OVER w`, `OVER (w ...)`), frames `ROWS`/`RANGE`/`GROUPS` with
  `UNBOUNDED PRECEDING`, `N PRECEDING`, `CURRENT ROW`, `N FOLLOWING`,
  `UNBOUNDED FOLLOWING`, and `EXCLUDE NO OTHERS|CURRENT ROW|GROUP|TIES`;
  `FILTER` on window aggregates.

### M8 — Reading SQLite database files

`minisql DBFILE` opens a database file written by SQLite and executes the
script against it. Tests create the file with real SQLite and then query it
with minisql. Required:

* The file header, any page size from 512 to 65536, UTF-8 text encoding.
* The schema table on page 1; tables, indexes (including
  `sqlite_autoindex_*`), and views defined there. Parse each object's
  `CREATE` statement from its `sql` column.
* Table b-trees and index b-trees (interior and leaf pages), the record
  format with all serial types, overflow pages, free pages and freeblocks
  (ignore their contents), `INTEGER PRIMARY KEY` aliasing (stored as NULL in
  the record), columns added by `ALTER TABLE ADD COLUMN` missing from older
  records (use the default).
* Every query feature from M1–M7 works on file databases.

### M9 — Writing SQLite database files

minisql writes changes back to `DBFILE` so that:

* After minisql exits, real SQLite can open the file, `PRAGMA
  integrity_check` returns `ok`, and every table, index and view has the
  contents minisql's statements produced. The `sql` column of each schema
  entry must be a `CREATE` statement SQLite can parse.
* A later minisql process sees everything committed earlier, and so does
  SQLite; SQLite can modify the file and minisql reads the changes.
* Each statement outside an explicit transaction commits when it finishes.
  An explicit transaction that is still open when the script ends is
  rolled back.
* Increment the schema cookie (offset 40) whenever the schema changes and
  the file change counter (offset 24) whenever the file changes; keep
  "version-valid-for" (offset 92) equal to the change counter and the
  database size (offset 28) equal to the real page count.
* An existing file keeps its page size. New files use 4096-byte pages.
* No rollback journal or crash recovery is required. The whole file may be
  rewritten when minisql exits.

## 5. File format reference

Milestones 8–9 use the SQLite 3 database file format as documented at
sqlite.org/fileformat2.html. Key points:

* 100-byte header on page 1 beginning `"SQLite format 3\0"`; page size at
  offset 16 (big-endian u16, value 1 means 65536); file change counter at
  24; database size in pages at 28; schema cookie at 40; schema format
  number 4 at 44; text encoding 1 (UTF-8) at 56; version-valid-for at 92
  and SQLite version number at 96.
* Page types: 0x02 interior index, 0x05 interior table, 0x0a leaf index,
  0x0d leaf table. B-tree page header is 8 bytes (leaf) or 12 bytes
  (interior); page 1's b-tree header follows the file header.
* Cells use big-endian varints (1–9 bytes). Records: header size varint,
  serial types, then the body. Serial types 0 NULL; 1–6 big-endian signed
  integers of 1, 2, 3, 4, 6, 8 bytes; 7 IEEE-754 double; 8 constant 0; 9
  constant 1; N≥12 even: blob of (N-12)/2 bytes; N≥13 odd: text of
  (N-13)/2 bytes.
* Payload overflow thresholds: with usable size U, table leaves store up to
  X = U-35 bytes locally; index pages up to X = ((U-12)*64/255)-23; when the
  payload P exceeds X, the local amount is M + ((P-M) % (U-4)) if that is
  ≤ X, else M, where M = ((U-12)*32/255)-23. Overflow pages start with a
  4-byte next-page number.
* The schema table has columns `type, name, tbl_name, rootpage, sql`.
