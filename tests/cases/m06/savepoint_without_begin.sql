-- A SAVEPOINT outside a transaction starts one. Releasing that outermost
-- savepoint commits; ROLLBACK TO it undoes changes but keeps the transaction
-- open; a plain ROLLBACK or COMMIT ends it.
CREATE TABLE t(v INTEGER);

SAVEPOINT outer1;
INSERT INTO t VALUES (1);
RELEASE outer1;
-- Committed: a ROLLBACK now has no transaction to roll back.
ROLLBACK;
SELECT v FROM t;

SAVEPOINT outer2;
INSERT INTO t VALUES (2);
ROLLBACK TO outer2;
-- The transaction is still open after ROLLBACK TO.
BEGIN;
INSERT INTO t VALUES (3);
RELEASE outer2;
SELECT v FROM t ORDER BY v;

-- COMMIT also ends a transaction started by SAVEPOINT.
SAVEPOINT outer3;
INSERT INTO t VALUES (4);
COMMIT;
SELECT v FROM t ORDER BY v;
RELEASE outer3;

-- ROLLBACK discards everything since the SAVEPOINT.
SAVEPOINT outer4;
INSERT INTO t VALUES (5);
SAVEPOINT inner4;
INSERT INTO t VALUES (6);
ROLLBACK;
SELECT v FROM t ORDER BY v;

-- Nested savepoints outside BEGIN: releasing the inner one does not commit.
SAVEPOINT a;
INSERT INTO t VALUES (7);
SAVEPOINT b;
INSERT INTO t VALUES (8);
RELEASE b;
ROLLBACK TO a;
RELEASE a;
SELECT v FROM t ORDER BY v;

-- ROLLBACK TO then COMMIT keeps only work done after the rollback.
SAVEPOINT c;
INSERT INTO t VALUES (9);
ROLLBACK TO c;
INSERT INTO t VALUES (10);
COMMIT;
SELECT v FROM t ORDER BY v;
