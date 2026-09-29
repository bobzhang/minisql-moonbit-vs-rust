-- @db file
-- Indexes whose CREATE INDEX text uses DESC columns, expressions, a WHERE
-- clause (partial index), COLLATE, and UNIQUE. The engine parses these
-- from sqlite_schema; results must match whatever plan it chooses.
-- @phase sqlite
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c REAL);
CREATE INDEX t_a_desc ON t(a DESC, b ASC);
CREATE INDEX t_lower_b ON t(lower(b));
CREATE INDEX t_c_big ON t(c) WHERE c > 100;
CREATE UNIQUE INDEX t_b_nocase ON t(b COLLATE NOCASE);
CREATE INDEX t_expr2 ON t(a * 10 + id, substr(b, 1, 2));
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 3000)
INSERT INTO t SELECT i, i % 37, CASE WHEN i % 2 THEN 'Item' ELSE 'ITEM' END || printf('%05d', i), i * 0.125 FROM n;
-- @phase engine
SELECT count(*), sum(a), sum(c) FROM t;
SELECT id, a, b FROM t WHERE a = 36 ORDER BY a DESC, b LIMIT 5;
SELECT id, b FROM t WHERE lower(b) = 'item00042';
SELECT count(*) FROM t WHERE lower(b) LIKE 'item001%';
SELECT id, c FROM t WHERE c > 374 ORDER BY c;
SELECT count(*), min(c), max(c) FROM t WHERE c > 100 AND c < 101;
SELECT count(*) FROM t WHERE c < 1;
SELECT id FROM t WHERE b = 'item00077' COLLATE NOCASE;
SELECT id FROM t WHERE b = 'item00077';
SELECT id, b FROM t ORDER BY b COLLATE NOCASE DESC LIMIT 3;
SELECT id FROM t WHERE a * 10 + id = 365 ORDER BY id;
SELECT a, count(*) FROM t WHERE a >= 35 GROUP BY a ORDER BY a DESC;
SELECT type, name, tbl_name FROM sqlite_schema WHERE type = 'index' ORDER BY name;
