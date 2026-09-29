-- @db file
-- Savepoints: ROLLBACK TO undoes only the work after the savepoint, RELEASE
-- of the outermost savepoint commits, and nested savepoints inside BEGIN
-- are committed by COMMIT. SQLite verifies the resulting file.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
CREATE INDEX t_v ON t(v);
SAVEPOINT a;
INSERT INTO t VALUES (1, 'a');
SAVEPOINT b;
INSERT INTO t VALUES (2, 'b');
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO t SELECT 100 + i, 'bulk' || i FROM c;
ROLLBACK TO b;
INSERT INTO t VALUES (3, 'after rollback to b');
RELEASE a;
BEGIN;
INSERT INTO t VALUES (4, 'in begin');
SAVEPOINT inner1;
CREATE TABLE side(x);
INSERT INTO side VALUES ('side');
SAVEPOINT inner2;
DELETE FROM t WHERE id = 1;
ROLLBACK TRANSACTION TO SAVEPOINT inner2;
RELEASE SAVEPOINT inner1;
COMMIT;
SAVEPOINT lone;
INSERT INTO t VALUES (5, 'lone');
ROLLBACK TO lone;
RELEASE lone;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT * FROM t ORDER BY id;
SELECT * FROM side;
