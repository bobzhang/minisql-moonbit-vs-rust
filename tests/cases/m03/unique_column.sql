-- Column-level UNIQUE constraints.
CREATE TABLE t(id INTEGER, email TEXT UNIQUE, code INTEGER UNIQUE);
INSERT INTO t VALUES (1, 'a@x', 10);
INSERT INTO t VALUES (2, 'b@x', 20);
-- Duplicate on either unique column fails.
INSERT INTO t VALUES (3, 'a@x', 30);
INSERT INTO t VALUES (4, 'c@x', 10);
SELECT * FROM t ORDER BY id;

-- NULLs are never equal to each other, so several NULLs are allowed.
INSERT INTO t VALUES (5, NULL, NULL);
INSERT INTO t VALUES (6, NULL, NULL);
SELECT * FROM t ORDER BY id;

-- Comparison is by value after affinity: '10' is converted to 10 in an
-- INTEGER column and collides with the existing 10.
INSERT INTO t VALUES (7, 'd@x', '10');
-- Case matters with the default BINARY collation.
INSERT INTO t VALUES (8, 'A@X', 80);
SELECT * FROM t ORDER BY id;

-- UPDATE into an existing value fails; updating a row to its own value is fine.
UPDATE t SET email = 'b@x' WHERE id = 1;
UPDATE t SET email = 'a@x' WHERE id = 1;
UPDATE t SET code = code WHERE id <= 2;
SELECT * FROM t ORDER BY id;

-- After a delete the value is free again.
DELETE FROM t WHERE id = 2;
INSERT INTO t VALUES (9, 'b@x', 20);
SELECT * FROM t ORDER BY id;

-- A column with no declared type: integer 1 and real 1.0 are equal values.
CREATE TABLE n(v UNIQUE);
INSERT INTO n VALUES (1);
INSERT INTO n VALUES (1.0);
-- but text '1' is a different value from integer 1.
INSERT INTO n VALUES ('1');
SELECT v, typeof(v) FROM n ORDER BY v;

-- Blobs participate too.
INSERT INTO n VALUES (x'01');
INSERT INTO n VALUES (x'01');
SELECT v, typeof(v) FROM n ORDER BY v;

-- Duplicates within a single multi-row INSERT.
CREATE TABLE m(v UNIQUE);
INSERT INTO m VALUES (1), (2), (1);
SELECT v FROM m ORDER BY v;
