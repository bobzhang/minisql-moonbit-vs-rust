-- @db file
-- @phase sqlite
PRAGMA page_size = 1024;
CREATE TABLE t(id INTEGER PRIMARY KEY, name TEXT, score REAL);
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
INSERT INTO t SELECT i, 'name' || i, i * 0.5 FROM n;
-- @phase engine
SELECT count(*), sum(score) FROM t;
SELECT name FROM t WHERE id = 1234;
