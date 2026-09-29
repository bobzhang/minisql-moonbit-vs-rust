-- @db file
-- ROLLBACK discards everything since BEGIN: inserted rows, deleted rows,
-- updates, created and dropped tables and indexes. SQLite must see the file
-- exactly as it was before the transaction.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX t_v ON t(v);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO t SELECT i, 'v' || i FROM c;
BEGIN;
DELETE FROM t WHERE id > 10;
UPDATE t SET v = 'changed';
CREATE TABLE tmp(x);
INSERT INTO tmp VALUES (1);
DROP INDEX t_v;
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO t SELECT 10000 + i, printf('%.*c', 3000, 'z') FROM c;
SELECT count(*) FROM t;
ROLLBACK;
SELECT count(*) FROM t;
BEGIN;
DROP TABLE t;
ROLLBACK TRANSACTION;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), sum(id), min(v), max(v) FROM t;
SELECT id FROM t INDEXED BY t_v WHERE v = 'v1234';
-- @phase engine
SELECT count(*) FROM t;
SELECT * FROM tmp;
BEGIN;
INSERT INTO t VALUES (3000, 'kept?');
ROLLBACK;
INSERT INTO t VALUES (3001, 'kept');
-- @phase sqlite
PRAGMA integrity_check;
SELECT id, v FROM t WHERE id > 2000 ORDER BY id;
