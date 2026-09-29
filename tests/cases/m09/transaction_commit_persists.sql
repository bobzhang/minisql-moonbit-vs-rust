-- @db file
-- Work done inside explicit transactions that are COMMITted (or ENDed)
-- persists, including schema changes and many rows; statements outside a
-- transaction commit on their own.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
BEGIN;
INSERT INTO t VALUES (1, 'one');
CREATE TABLE u(x INTEGER);
INSERT INTO u VALUES (10);
COMMIT;
INSERT INTO t VALUES (2, 'two');
BEGIN IMMEDIATE TRANSACTION;
WITH RECURSIVE c(i) AS (SELECT 3 UNION ALL SELECT i + 1 FROM c WHERE i < 5000)
INSERT INTO t SELECT i, 'row' || i FROM c;
CREATE INDEX t_v ON t(v);
UPDATE u SET x = x + 1;
END TRANSACTION;
BEGIN EXCLUSIVE;
DELETE FROM t WHERE id > 4000;
COMMIT TRANSACTION;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT count(*), max(id) FROM t;
SELECT * FROM t WHERE id <= 3 ORDER BY id;
SELECT * FROM u;
SELECT id FROM t INDEXED BY t_v WHERE v = 'row3999';
-- @phase engine
BEGIN DEFERRED;
INSERT INTO u VALUES (20);
COMMIT;
SELECT * FROM u ORDER BY x;
-- @phase sqlite
SELECT * FROM u ORDER BY x;
