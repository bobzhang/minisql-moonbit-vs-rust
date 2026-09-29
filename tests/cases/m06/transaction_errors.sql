-- Errors in transaction control: nested BEGIN, COMMIT/END/ROLLBACK without an
-- active transaction. An error does not end or change the current transaction.
CREATE TABLE t(v INTEGER);

COMMIT;
ROLLBACK;
BEGIN;
INSERT INTO t VALUES (1);
-- Nested BEGIN fails, and the outer transaction continues.
BEGIN;
INSERT INTO t VALUES (2);
SELECT v FROM t ORDER BY v;
ROLLBACK;
-- Both inserts were part of the outer transaction and are undone.
SELECT count(*) FROM t;
-- After ROLLBACK there is no transaction, so COMMIT fails again.
COMMIT;
-- Autocommit mode: each statement is committed immediately.
INSERT INTO t VALUES (3);
ROLLBACK;
SELECT v FROM t;
-- A failed BEGIN inside a transaction does not commit it.
BEGIN;
INSERT INTO t VALUES (4);
BEGIN;
ROLLBACK;
SELECT v FROM t ORDER BY v;
-- A syntax error inside a transaction leaves it open.
BEGIN;
INSERT INTO t VALUES (5);
INSERT INTO t VALUES (;
INSERT INTO t VALUES (6);
COMMIT;
SELECT v FROM t ORDER BY v;
-- Unknown transaction keywords are syntax errors.
BEGIN SOMETIMES;
SELECT count(*) FROM t;
COMMIT;
-- Normal transactions work after all the errors.
BEGIN;
INSERT INTO t VALUES (7);
UPDATE t SET v = v * 10 WHERE v = 7;
COMMIT;
SELECT v FROM t ORDER BY v;
BEGIN;
DELETE FROM t WHERE v > 5;
SELECT count(*) FROM t;
END;
SELECT v FROM t ORDER BY v;
