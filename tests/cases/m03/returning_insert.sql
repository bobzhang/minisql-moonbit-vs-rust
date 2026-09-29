-- INSERT ... RETURNING returns one row per inserted row, showing the values
-- actually stored (after defaults, affinity and rowid assignment).
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT DEFAULT 'dflt', c REAL);

INSERT INTO t(a) VALUES ('5') RETURNING *;
INSERT INTO t(a, c) VALUES (1, 2), (2, 3) RETURNING id, a * 10 AS x, typeof(a), c, typeof(c);
INSERT INTO t VALUES (10, 7, 'seven', NULL) RETURNING rowid, oid, _rowid_;
INSERT INTO t(b) VALUES (NULL) RETURNING id, a, b;

-- Expressions and functions in RETURNING.
INSERT INTO t(a, b) VALUES (3, 'abc') RETURNING upper(b) || '-' || a, length(b), a > 2;
INSERT INTO t(a) VALUES (4) RETURNING 'constant', NULL, 1 + 1;

-- RETURNING with a multi-row INSERT lists rows in insertion order.
INSERT INTO t(a, b) VALUES (100, 'x'), (200, 'y'), (300, 'z') RETURNING a, b;

-- INSERT ... SELECT ... RETURNING.
CREATE TABLE dst(n INTEGER, label TEXT);
INSERT INTO dst SELECT a, b FROM t WHERE a >= 100 ORDER BY a DESC RETURNING rowid, n, label;

-- DEFAULT VALUES ... RETURNING.
INSERT INTO t DEFAULT VALUES RETURNING id, b;

-- Upsert DO NOTHING returns nothing for the skipped row.
INSERT INTO t VALUES (1, 0, 'dup', 0) ON CONFLICT DO NOTHING RETURNING id;
-- Upsert DO UPDATE returns the updated row.
INSERT INTO t VALUES (1, 0, 'updated', 0) ON CONFLICT(id) DO UPDATE SET b = excluded.b RETURNING id, a, b;

-- OR IGNORE returns only the rows actually inserted.
INSERT OR IGNORE INTO t(id, a) VALUES (1, 1), (50, 50), (2, 2) RETURNING id, a;
-- OR REPLACE returns the new row.
INSERT OR REPLACE INTO t(id, a, b) VALUES (2, 22, 'replaced') RETURNING *;

-- A failing INSERT returns no rows at all, not even for rows before the
-- failure.
INSERT INTO t(id, a) VALUES (60, 60), (1, 1) RETURNING id;
SELECT id, a, b, c FROM t ORDER BY id;

-- Errors in the RETURNING list.
INSERT INTO t(a) VALUES (1) RETURNING nosuch;
INSERT INTO t(a) VALUES (1) RETURNING count(*);
SELECT id FROM t WHERE id >= 50 ORDER BY id;
