-- All SET expressions in an UPDATE see the row's OLD values, so swapping
-- columns works. Affinity is applied to the new values.
CREATE TABLE t(id INTEGER, a INTEGER, b TEXT, c REAL, d);
INSERT INTO t VALUES (1, 10, 'x', 1.5, 'q'), (2, 20, 'y', 2.5, NULL), (3, 30, 'z', 3.5, 7);

-- Swap: both right-hand sides use old values.
UPDATE t SET a = id, id = a;
SELECT id, a FROM t ORDER BY id;
UPDATE t SET a = id, id = a;
SELECT id, a FROM t ORDER BY id;

-- A later SET uses the old value, not the one just assigned.
UPDATE t SET a = a + 1, c = a WHERE id = 1;
SELECT id, a, c FROM t ORDER BY id;

-- Assigning the same column twice: the last assignment wins.
UPDATE t SET d = 'first', d = 'second' WHERE id = 2;
SELECT id, d FROM t ORDER BY id;

-- Affinity on UPDATE: INTEGER column converts '42', TEXT column converts 5.
UPDATE t SET a = '42', b = 5, c = '6' WHERE id = 3;
SELECT a, typeof(a), b, typeof(b), c, typeof(c) FROM t WHERE id = 3;
-- A REAL column stores an integer as REAL; an INTEGER column keeps '4.0' as 4.
UPDATE t SET c = 8, a = '4.0' WHERE id = 2;
SELECT a, typeof(a), c, typeof(c) FROM t WHERE id = 2;
-- Text that is not numeric stays text in an INTEGER column.
UPDATE t SET a = 'abc' WHERE id = 1;
SELECT a, typeof(a) FROM t WHERE id = 1;
-- A column with no type (d) keeps what it is given.
UPDATE t SET d = '12' WHERE id = 1;
SELECT d, typeof(d) FROM t WHERE id = 1;

-- Expressions using functions and CASE.
UPDATE t SET b = CASE WHEN id % 2 = 1 THEN upper(b) ELSE b || b END;
SELECT id, b FROM t ORDER BY id;
UPDATE t SET d = printf('%s-%d', b, id);
SELECT id, d FROM t ORDER BY id;

-- WHERE uses old values too.
UPDATE t SET id = id + 100 WHERE id < 3;
SELECT id FROM t ORDER BY id;
