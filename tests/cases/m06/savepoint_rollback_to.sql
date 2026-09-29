-- ROLLBACK TO undoes changes but leaves the savepoint (and the transaction)
-- open: it can be rolled back to repeatedly, and the work after it can
-- continue and later be released or committed.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT);
INSERT INTO t VALUES (1, 'orig');

BEGIN;
SAVEPOINT sp;
UPDATE t SET v = 'first try';
ROLLBACK TO sp;
SELECT v FROM t;
UPDATE t SET v = 'second try';
ROLLBACK TO sp;
SELECT v FROM t;
UPDATE t SET v = 'third try';
INSERT INTO t VALUES (2, 'new');
-- Still inside the savepoint: another ROLLBACK TO undoes both.
ROLLBACK TO sp;
SELECT id, v FROM t ORDER BY id;
INSERT INTO t VALUES (3, 'kept');
RELEASE sp;
COMMIT;
SELECT id, v FROM t ORDER BY id;
-- Rolling back to a savepoint does not end the enclosing transaction; the
-- outer ROLLBACK still discards changes made before the savepoint.
BEGIN;
DELETE FROM t WHERE id = 1;
SAVEPOINT sp2;
DELETE FROM t;
ROLLBACK TO sp2;
SELECT id FROM t ORDER BY id;
ROLLBACK;
SELECT id FROM t ORDER BY id;
-- ROLLBACK TO restores DDL too.
BEGIN;
SAVEPOINT ddl;
CREATE TABLE extra(x);
CREATE INDEX t_v ON t(v);
ALTER TABLE t ADD COLUMN w DEFAULT 'w';
DROP TABLE extra;
CREATE TABLE extra2(y);
ROLLBACK TO ddl;
SELECT type, name FROM sqlite_schema ORDER BY name;
SELECT * FROM t ORDER BY id;
RELEASE ddl;
COMMIT;
-- Rows deleted and re-inserted within the savepoint are restored exactly.
BEGIN;
SAVEPOINT rows;
DELETE FROM t;
INSERT INTO t VALUES (1, 'imposter');
ROLLBACK TO rows;
COMMIT;
SELECT id, v FROM t ORDER BY id;
