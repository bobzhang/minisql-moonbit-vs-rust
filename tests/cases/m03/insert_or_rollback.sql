-- INSERT OR ROLLBACK: outside an explicit transaction this behaves like
-- ABORT: the failing statement leaves no changes and later statements run
-- normally.
CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT UNIQUE);
INSERT INTO t VALUES (1, 'a'), (2, 'b');

INSERT OR ROLLBACK INTO t VALUES (3, 'c'), (4, 'a'), (5, 'e');
SELECT id, v FROM t ORDER BY id;

INSERT OR ROLLBACK INTO t VALUES (3, 'c');
SELECT id, v FROM t ORDER BY id;

-- Primary key conflict.
INSERT OR ROLLBACK INTO t VALUES (6, 'f'), (1, 'z');
SELECT id, v FROM t ORDER BY id;

-- Constraint-level ON CONFLICT ROLLBACK.
CREATE TABLE r(k INTEGER UNIQUE ON CONFLICT ROLLBACK, w TEXT);
INSERT INTO r VALUES (1, 'x');
INSERT INTO r VALUES (2, 'y'), (1, 'dup'), (3, 'z');
SELECT k, w FROM r ORDER BY k;
INSERT INTO r VALUES (2, 'y');
SELECT k, w FROM r ORDER BY k;

-- UPDATE OR ROLLBACK.
UPDATE OR ROLLBACK t SET v = 'a' WHERE id = 3;
SELECT id, v FROM t ORDER BY id;
UPDATE OR ROLLBACK t SET v = v || '!' WHERE id >= 2;
SELECT id, v FROM t ORDER BY id;

-- NOT NULL ON CONFLICT ROLLBACK.
CREATE TABLE n(x NOT NULL ON CONFLICT ROLLBACK);
INSERT INTO n VALUES (1), (NULL);
INSERT INTO n VALUES (2);
SELECT x FROM n ORDER BY x;
