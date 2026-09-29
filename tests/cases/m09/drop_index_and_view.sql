-- @db file
-- DROP INDEX frees the index b-tree; DROP VIEW removes only the schema
-- row. New indexes and views created afterwards (including one with the
-- same name but a different definition) must be correct.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO t SELECT i, i % 50, 'b' || (i % 300) FROM c;
CREATE INDEX t_a ON t(a);
CREATE INDEX t_b ON t(b);
CREATE VIEW v AS SELECT a, count(*) AS n FROM t GROUP BY a;
DROP INDEX t_a;
DROP VIEW v;
CREATE INDEX t_a ON t(a, b);
CREATE VIEW v AS SELECT b, sum(a) AS s FROM t GROUP BY b;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM v WHERE b IN ('b1', 'b299') ORDER BY b;
SELECT count(*) FROM t INDEXED BY t_a WHERE a = 3 AND b = 'b103';
SELECT count(*) FROM t INDEXED BY t_b WHERE b = 'b7';
-- @phase engine
DROP INDEX t_b;
DROP INDEX IF EXISTS t_b;
DROP INDEX t_b;
DROP VIEW IF EXISTS no_such_view;
DROP VIEW v;
CREATE UNIQUE INDEX t_ab_id ON t(a, b, id);
SELECT type, name FROM sqlite_schema ORDER BY name;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*) FROM t INDEXED BY t_ab_id WHERE a = 49;
