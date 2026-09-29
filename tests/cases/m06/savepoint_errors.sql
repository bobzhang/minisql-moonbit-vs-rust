-- Savepoint errors: releasing or rolling back to a savepoint that does not
-- exist (never created, already released, or discarded by an outer rollback).
-- An error does not affect the transaction or the savepoints that exist.
CREATE TABLE t(v INTEGER);

RELEASE nosuch;
ROLLBACK TO nosuch;
BEGIN;
SAVEPOINT a;
INSERT INTO t VALUES (1);
SAVEPOINT b;
INSERT INTO t VALUES (2);
RELEASE nosuch;
-- a and b are still usable after the error.
ROLLBACK TO b;
SELECT v FROM t ORDER BY v;
RELEASE b;
-- b no longer exists.
ROLLBACK TO b;
RELEASE b;
-- a still exists.
SAVEPOINT c;
INSERT INTO t VALUES (3);
ROLLBACK TO a;
-- ROLLBACK TO a discarded c.
RELEASE c;
SELECT count(*) FROM t;
INSERT INTO t VALUES (4);
COMMIT;
SELECT v FROM t ORDER BY v;
-- After COMMIT no savepoints remain.
ROLLBACK TO a;
-- A savepoint name that differs only in case is the same savepoint.
BEGIN;
SAVEPOINT Alpha;
INSERT INTO t VALUES (5);
ROLLBACK TO ALPHA;
RELEASE alpha;
COMMIT;
SELECT v FROM t ORDER BY v;
-- BEGIN is not allowed inside a savepoint-started transaction either.
SAVEPOINT s;
INSERT INTO t VALUES (6);
BEGIN;
RELEASE s;
SELECT v FROM t ORDER BY v;
-- Savepoints and normal transactions after the errors.
SAVEPOINT z;
DELETE FROM t WHERE v = 4;
ROLLBACK TO z;
RELEASE z;
SELECT count(*) FROM t;
