-- NOT NULL constraints on INSERT and UPDATE.
CREATE TABLE t(id INTEGER, name TEXT NOT NULL, note TEXT);
INSERT INTO t VALUES (1, 'a', NULL);
INSERT INTO t VALUES (2, NULL, 'x');
INSERT INTO t(id, note) VALUES (3, 'y');
SELECT * FROM t ORDER BY id;

-- Empty string and 0 are not NULL.
INSERT INTO t VALUES (4, '', 'empty');
INSERT INTO t VALUES (5, 0, 'zero');
SELECT id, name, typeof(name) FROM t ORDER BY id;

-- UPDATE to NULL fails and leaves the row unchanged.
UPDATE t SET name = NULL WHERE id = 1;
UPDATE t SET name = nullif(name, 'zzz');
SELECT id, name FROM t ORDER BY id;
SELECT id, name FROM t ORDER BY id;

-- An expression evaluating to NULL is also rejected.
INSERT INTO t VALUES (6, 1 / 0, 'div');
INSERT INTO t VALUES (7, CAST(12 AS TEXT), 'cast');
SELECT id, name, typeof(name) FROM t WHERE id = 7;
SELECT id FROM t ORDER BY id;

-- NOT NULL with a DEFAULT: omitting the column uses the default.
CREATE TABLE d(id INTEGER, v INTEGER NOT NULL DEFAULT 42);
INSERT INTO d(id) VALUES (1);
-- Explicit NULL is still an error even though a default exists.
INSERT INTO d VALUES (2, NULL);
SELECT * FROM d ORDER BY id;

-- NOT NULL written after other constraints, and a named constraint.
CREATE TABLE n(a UNIQUE NOT NULL, b CONSTRAINT b_nn NOT NULL);
INSERT INTO n VALUES (1, 1);
INSERT INTO n VALUES (NULL, 2);
INSERT INTO n VALUES (3, 'three');
UPDATE n SET b = b || '!' WHERE a IS NOT NULL;
SELECT a, b FROM n ORDER BY a;

-- Multi-row INSERT: a NULL in the second row rejects the whole statement.
INSERT INTO n VALUES (10, 10), (11, NULL), (12, 12);
SELECT a, b FROM n ORDER BY a;

-- INSERT ... SELECT that yields a NULL fails as a whole.
CREATE TABLE s(v);
INSERT INTO s VALUES (1), (NULL), (3);
INSERT INTO n SELECT v + 100, v FROM s;
SELECT a, b FROM n ORDER BY a;
INSERT INTO n SELECT v + 100, v FROM s WHERE v IS NOT NULL;
SELECT a, b FROM n ORDER BY a;
