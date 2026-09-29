-- @db file
-- SQLite and the engine alternate writing the same file. Each side must
-- see the other's committed changes to data and schema. This exercises the
-- header fields the writer maintains (page count, freelist, change counter,
-- schema cookie) in both directions.
-- @phase sqlite
PRAGMA page_size = 2048;
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1000)
INSERT INTO t SELECT i, 'sqlite' || i FROM c;
-- @phase engine
SELECT count(*) FROM t;
WITH RECURSIVE c(i) AS (SELECT 1001 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO t SELECT i, 'engine' || i FROM c;
DELETE FROM t WHERE id % 3 = 0;
CREATE TABLE e(x INTEGER UNIQUE);
INSERT INTO e VALUES (1), (2);
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), min(v), max(v) FROM t;
SELECT * FROM e ORDER BY x;
UPDATE t SET v = v || '!' WHERE id % 5 = 0;
DROP INDEX t_v;
CREATE INDEX t_v2 ON t(v DESC);
CREATE TABLE s(y);
INSERT INTO s VALUES ('from sqlite');
DELETE FROM e WHERE x = 1;
-- @phase engine
SELECT count(*), sum(v LIKE '%!') FROM t;
SELECT * FROM s;
SELECT * FROM e;
SELECT type, name FROM sqlite_schema ORDER BY name;
INSERT INTO t VALUES (5000, 'engine again');
INSERT INTO e VALUES (2);
INSERT INTO e VALUES (3);
DROP TABLE s;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT id FROM t INDEXED BY t_v2 WHERE v = 'engine again';
SELECT * FROM e ORDER BY x;
SELECT count(*) FROM t;
-- @phase engine
SELECT count(*), max(id) FROM t;
SELECT id, v FROM t ORDER BY v DESC LIMIT 2;
