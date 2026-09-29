-- A statement that fails inside a transaction is undone by itself (statement
-- atomicity) but the transaction stays open and earlier statements are kept.
-- The exception is ON CONFLICT ROLLBACK / INSERT OR ROLLBACK, which rolls back
-- the whole transaction.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT NOT NULL, u INTEGER UNIQUE);
INSERT INTO t VALUES (1, 'a', 10);

BEGIN;
INSERT INTO t VALUES (2, 'b', 20);
-- Fails on the second row: neither row of this statement stays.
INSERT INTO t VALUES (3, 'c', 30), (4, 'd', 10);
INSERT INTO t VALUES (5, 'e', 50);
COMMIT;
SELECT id FROM t ORDER BY id;
-- Constraint errors of several kinds inside one transaction.
BEGIN;
UPDATE t SET v = NULL WHERE id = 1;
UPDATE t SET u = 20 WHERE id = 5;
UPDATE t SET v = 'changed' WHERE id = 1;
DELETE FROM t WHERE id = 2;
COMMIT;
SELECT id, v, u FROM t ORDER BY id;
-- A multi-row UPDATE failing on one row changes nothing.
BEGIN;
UPDATE t SET v = CASE WHEN id = 5 THEN NULL ELSE v || '!' END;
SELECT id, v FROM t ORDER BY id;
UPDATE t SET u = u + 1000;
SELECT id, u FROM t ORDER BY id;
ROLLBACK;
SELECT id, u FROM t ORDER BY id;
-- INSERT OR ROLLBACK aborts the whole transaction on conflict...
BEGIN;
INSERT INTO t VALUES (6, 'f', 60);
INSERT OR ROLLBACK INTO t VALUES (7, 'g', 10);
-- ...so there is nothing left to commit.
COMMIT;
SELECT id FROM t ORDER BY id;
-- INSERT OR FAIL keeps rows written before the failing row of the same statement.
BEGIN;
INSERT OR FAIL INTO t VALUES (8, 'h', 80), (9, 'i', 10), (11, 'k', 110);
COMMIT;
SELECT id FROM t ORDER BY id;
-- INSERT OR ABORT (the default) undoes the whole statement but keeps the transaction.
BEGIN;
INSERT INTO t VALUES (12, 'l', 120);
INSERT OR ABORT INTO t VALUES (13, 'm', 130), (14, 'n', 10);
COMMIT;
SELECT id FROM t ORDER BY id;
-- Runtime errors inside a transaction behave the same way.
BEGIN;
INSERT INTO t VALUES (15, 'o', 150);
SELECT nosuchfunc(1);
INSERT INTO nosuch VALUES (1);
COMMIT;
SELECT count(*) FROM t;
