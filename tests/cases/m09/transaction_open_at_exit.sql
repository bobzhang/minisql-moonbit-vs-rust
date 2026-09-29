-- @db file
-- A transaction that is still open when the script ends is rolled back:
-- nothing from it reaches the file. Work committed earlier in the same
-- script stays.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'committed');
BEGIN;
INSERT INTO t VALUES (2, 'committed in txn');
COMMIT;
BEGIN;
INSERT INTO t VALUES (3, 'never');
UPDATE t SET v = 'never' WHERE id = 1;
CREATE TABLE ghost(x);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT 100 + i, 'ghost' FROM c;
SELECT count(*) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT * FROM t ORDER BY id;
-- @phase engine
SELECT * FROM t ORDER BY id;
SELECT * FROM ghost;
BEGIN;
DROP TABLE t;
-- @phase engine
SELECT count(*) FROM t;
SAVEPOINT s1;
INSERT INTO t VALUES (4, 'savepoint never released');
-- @phase sqlite
PRAGMA integrity_check;
SELECT * FROM t ORDER BY id;
