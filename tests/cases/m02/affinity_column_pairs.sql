-- Comparison affinity between two columns:
--   numeric (INTEGER/REAL/NUMERIC) vs TEXT/BLOB/none -> NUMERIC applied to the other;
--   TEXT vs none (BLOB affinity)                       -> TEXT applied to the other;
--   otherwise no conversion.

CREATE TABLE t(id INTEGER, i INTEGER, r REAL, s TEXT, b BLOB, u);
INSERT INTO t VALUES (1, 1, 1.0, '1', '1', '1');
INSERT INTO t VALUES (2, 2, 2.0, '2.0', '2.0', 2);
INSERT INTO t VALUES (3, 3, 3.5, 'x', 'x', 'x');
INSERT INTO t VALUES (4, 10, 10.0, '9', '9', '9');
SELECT id, typeof(i), typeof(r), typeof(s), typeof(b), typeof(u) FROM t ORDER BY id;
-- INTEGER vs TEXT column: the text is converted when it looks numeric.
SELECT id, i = s, s = i, i > s FROM t ORDER BY id;
-- REAL vs TEXT.
SELECT id, r = s FROM t ORDER BY id;
-- INTEGER vs BLOB-affinity column and vs untyped column: numeric wins.
SELECT id, i = b, i = u, u = i FROM t ORDER BY id;
-- TEXT vs untyped column: TEXT is applied to the untyped value.
SELECT id, s = u, u = s FROM t ORDER BY id;
-- BLOB-affinity vs untyped: no conversion.
SELECT id, b = u FROM t ORDER BY id;
-- INTEGER vs REAL: both numeric.
SELECT id, i = r, i < r FROM t ORDER BY id;
-- In WHERE with ordering comparisons.
SELECT id FROM t WHERE i > s ORDER BY id;
SELECT id FROM t WHERE s <= u ORDER BY id;
