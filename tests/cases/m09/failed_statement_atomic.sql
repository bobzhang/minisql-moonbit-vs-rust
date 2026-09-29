-- @db file
-- A statement that fails part-way leaves no partial changes in the file:
-- a multi-row INSERT hitting a UNIQUE violation, an UPDATE that breaks a
-- CHECK on some rows, an INSERT ... SELECT hitting NOT NULL. INSERT OR FAIL
-- keeps the rows inserted before the failing one; a runtime error in an
-- UPDATE undoes the rows it already changed; OR IGNORE and OR REPLACE
-- resolve conflicts. SQLite checks the file matches.
-- @phase engine
CREATE TABLE t(id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL CHECK (n >= 0));
CREATE INDEX t_n ON t(n);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 1000)
INSERT INTO t SELECT i, 'u' || i, i FROM c;
INSERT INTO t VALUES (2001, 'new1', 1), (2002, 'new2', 2), (2003, 'u500', 3), (2004, 'new4', 4);
WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < 3000)
INSERT INTO t SELECT 5000 + i, 'bulk' || i, CASE WHEN i = 2999 THEN NULL ELSE i END FROM c;
UPDATE t SET n = n - 500;
UPDATE t SET u = 'same' WHERE id > 990;
-- A runtime error (integer overflow in abs) when the UPDATE reaches row 700.
UPDATE t SET n = CASE WHEN id = 700 THEN abs(-9223372036854775807 - 1) ELSE n + 1 END;
DELETE FROM t WHERE id = 1;
INSERT OR FAIL INTO t VALUES (3001, 'f1', 1), (3002, 'f2', 2), (3003, 'u7', 3), (3004, 'f4', 4);
INSERT OR IGNORE INTO t VALUES (3005, 'u8', 5), (3006, 'i6', 6);
INSERT OR REPLACE INTO t VALUES (3007, 'u9', 9);
SELECT count(*), sum(n) FROM t;
-- @phase sqlite
PRAGMA integrity_check;
SELECT count(*), sum(n), max(id) FROM t;
SELECT id, u, n FROM t WHERE id > 990 ORDER BY id;
SELECT count(*) FROM t INDEXED BY t_n WHERE n < 0;
SELECT id FROM t INDEXED BY sqlite_autoindex_t_1 WHERE u = 'u9';
-- @phase engine
BEGIN;
INSERT INTO t VALUES (4001, 'txn1', 1);
INSERT INTO t VALUES (4002, 'u10', 2);
INSERT INTO t VALUES (4003, 'txn3', 3);
COMMIT;
INSERT OR ROLLBACK INTO t VALUES (4004, 'u11', 4);
BEGIN;
INSERT INTO t VALUES (4005, 'rolled back', 5);
INSERT OR ROLLBACK INTO t VALUES (4006, 'u12', 6);
COMMIT;
-- @phase sqlite
PRAGMA integrity_check;
SELECT id, u FROM t WHERE id > 4000 ORDER BY id;
SELECT count(*) FROM t;
