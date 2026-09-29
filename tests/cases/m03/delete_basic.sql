-- DELETE FROM t [WHERE ...].
CREATE TABLE t(id INTEGER, grp TEXT, v REAL);
INSERT INTO t VALUES (1, 'a', 1.0), (2, 'b', NULL), (3, 'a', 3.5), (4, 'c', -2.0), (5, 'b', 0.0), (6, NULL, 9.0);

DELETE FROM t WHERE id = 3;
SELECT * FROM t ORDER BY id;

-- WHERE with NULL: rows where the condition is NULL are kept.
DELETE FROM t WHERE v > 0.5;
SELECT * FROM t ORDER BY id;
DELETE FROM t WHERE grp = NULL;
SELECT * FROM t ORDER BY id;
DELETE FROM t WHERE grp IS NULL;
SELECT * FROM t ORDER BY id;

-- WHERE with OR, IN, LIKE.
INSERT INTO t VALUES (7, 'dd', 1.0), (8, 'de', 2.0), (9, 'e', 3.0);
DELETE FROM t WHERE grp LIKE 'd%' OR id IN (4);
SELECT * FROM t ORDER BY id;

-- Matching nothing.
DELETE FROM t WHERE 0;
SELECT id FROM t ORDER BY id;

-- DELETE by rowid.
DELETE FROM t WHERE rowid = 2;
SELECT rowid, id FROM t ORDER BY id;

-- DELETE with no WHERE empties the table; the table still exists.
DELETE FROM t;
SELECT * FROM t;
INSERT INTO t VALUES (10, 'z', 1.5);
SELECT * FROM t ORDER BY id;

-- Deleting from an empty table.
CREATE TABLE e(a);
DELETE FROM e;
DELETE FROM e WHERE a = 1;
SELECT a FROM e;

-- Errors.
DELETE FROM nosuch;
DELETE FROM t WHERE nosuch = 1;
DELETE t WHERE id = 10;
SELECT * FROM t ORDER BY id;
