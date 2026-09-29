-- @db file
-- Expression indexes store the computed value of the expression; partial
-- indexes contain only rows satisfying their WHERE clause. integrity_check
-- recomputes both, so the engine's index contents must be exactly right,
-- also after UPDATEs move rows into and out of the partial index.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c REAL);
CREATE INDEX t_lower ON t(lower(b));
CREATE INDEX t_expr ON t(a * 2 + 1, substr(b, 1, 3));
CREATE INDEX t_big_c ON t(c) WHERE c > 100;
CREATE UNIQUE INDEX t_partial_unique ON t(a) WHERE b LIKE 'U%';
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
INSERT INTO t SELECT i, i, CASE WHEN i % 10 = 0 THEN 'Unique' ELSE 'Item' END || i, i * 0.25 FROM n;
UPDATE t SET c = c + 100 WHERE id % 3 = 0;
UPDATE t SET c = 1 WHERE id > 1900;
UPDATE t SET b = upper(b) WHERE id % 7 = 0;
INSERT INTO t VALUES (3000, 10, 'Ux', 0);
INSERT INTO t VALUES (3001, 10, 'x', 0);
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*) FROM t INDEXED BY t_lower WHERE lower(b) = 'item77';
SELECT count(*) FROM t INDEXED BY t_expr WHERE a * 2 + 1 = 21 AND substr(b, 1, 3) = 'Uni';
SELECT count(*), sum(id) FROM t INDEXED BY t_big_c WHERE c > 100;
SELECT count(*) FROM t INDEXED BY t_partial_unique WHERE b LIKE 'U%' AND a = 20;
INSERT INTO t VALUES (3002, 20, 'Uy', 0);
INSERT INTO t VALUES (3003, 20, 'y', 0);
PRAGMA integrity_check;
