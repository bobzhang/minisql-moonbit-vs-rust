-- CREATE INDEX / DROP INDEX: indexes never change query results, and they
-- appear in sqlite_schema with type 'index' and tbl_name = their table.
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES (1, 5, 'x', 1.5), (2, 3, 'y', 2.5), (3, 5, 'z', NULL), (4, NULL, 'x', 0.5), (5, 1, NULL, 9.0);

SELECT id FROM t WHERE a = 5 ORDER BY id;
CREATE INDEX t_a ON t(a);
-- Same results with the index.
SELECT id FROM t WHERE a = 5 ORDER BY id;
SELECT id FROM t WHERE a > 2 ORDER BY id;
SELECT id FROM t WHERE a IS NULL;
SELECT a, count(*) FROM t GROUP BY a ORDER BY a;
-- Multi-column index.
CREATE INDEX t_b_c ON t(b, c);
SELECT id FROM t WHERE b = 'x' ORDER BY id;
SELECT id FROM t WHERE b = 'x' AND c > 1 ORDER BY id;
SELECT id FROM t WHERE c < 2 ORDER BY id;
-- Index with explicit ASC/DESC per column.
CREATE INDEX t_mixed ON t(a ASC, b DESC);
SELECT id FROM t WHERE a = 5 ORDER BY b DESC;
-- Several indexes on the same column are allowed.
CREATE INDEX t_a2 ON t(a);
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
-- DROP INDEX removes it; queries still work.
DROP INDEX t_a;
DROP INDEX t_a2;
SELECT id FROM t WHERE a = 5 ORDER BY id;
SELECT name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
-- An index on an empty table, then inserts.
CREATE TABLE e(k TEXT);
CREATE INDEX e_k ON e(k);
INSERT INTO e VALUES ('b'), ('a'), ('b');
SELECT count(*) FROM e WHERE k = 'b';
SELECT k FROM e ORDER BY k;
-- Index names are case-insensitive for DROP.
CREATE INDEX MixedCase ON e(k);
DROP INDEX mixedcase;
SELECT count(*) FROM sqlite_schema WHERE type = 'index';
