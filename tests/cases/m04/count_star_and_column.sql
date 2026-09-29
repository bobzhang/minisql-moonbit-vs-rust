-- count(*) counts rows; count(x) counts rows where x is not NULL.
CREATE TABLE t(id INTEGER, a, b TEXT);
INSERT INTO t VALUES (1, 10, 'x'), (2, NULL, 'y'), (3, 0, NULL), (4, '', ''), (5, NULL, NULL), (6, x'', 'z');

SELECT count(*), count(a), count(b), count(id) FROM t;
-- Empty string, 0 and empty blob are not NULL.
SELECT count(a) FROM t WHERE id IN (3, 4, 6);
-- count of a constant / expression.
SELECT count(1), count(NULL), count('x'), count(a + 1), count(a || b) FROM t;
-- COUNT is case-insensitive and ignores spaces.
SELECT COUNT( * ), Count(a) FROM t;

-- With WHERE.
SELECT count(*) FROM t WHERE a IS NULL;
SELECT count(*) FROM t WHERE b > 'x';
SELECT count(b) FROM t WHERE id > 2;

-- On an empty table and with a WHERE that matches nothing: one row, 0.
CREATE TABLE e(x);
SELECT count(*), count(x) FROM e;
SELECT count(*) FROM t WHERE id > 100;

-- count(*) result type.
SELECT typeof(count(*)), typeof(count(a)) FROM t;

-- count over a table with only NULLs.
CREATE TABLE n(x);
INSERT INTO n VALUES (NULL), (NULL), (NULL);
SELECT count(*), count(x) FROM n;

-- count in arithmetic.
SELECT count(*) * 2 + count(a), count(*) - count(b) FROM t;
SELECT count(a) * 1.0 / count(*) FROM t;

-- count after DELETE and INSERT.
DELETE FROM t WHERE a IS NULL;
SELECT count(*), count(a) FROM t;
INSERT INTO t SELECT id + 10, a, b FROM t;
SELECT count(*), count(a), count(b) FROM t;

-- count(*) with a large table built from itself.
CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (0), (1), (2), (3), (4), (5), (6), (7), (8), (9);
INSERT INTO d SELECT x + 10 FROM d;
INSERT INTO d SELECT x + 20 FROM d;
SELECT count(*), count(DISTINCT x % 7) FROM d;
