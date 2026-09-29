-- SELECT DISTINCT removes duplicate result rows. NULLs are considered equal
-- to each other for DISTINCT.
CREATE TABLE t(a, b);
INSERT INTO t VALUES (1, 'x'), (1, 'x'), (2, 'x'), (1, 'y'), (NULL, 'x'), (NULL, 'x'), (NULL, NULL), (NULL, NULL), (2, 'x');

SELECT DISTINCT a FROM t ORDER BY a;
SELECT DISTINCT b FROM t ORDER BY b;
SELECT DISTINCT a, b FROM t ORDER BY a, b;
SELECT DISTINCT a, b FROM t ORDER BY b DESC, a DESC;

-- ALL is the default and keeps duplicates.
SELECT ALL a FROM t WHERE b = 'x' ORDER BY a;

-- DISTINCT on an expression.
SELECT DISTINCT a * 0 FROM t ORDER BY 1;
SELECT DISTINCT length(b) FROM t ORDER BY 1;
SELECT DISTINCT typeof(a) FROM t ORDER BY 1;

-- DISTINCT then LIMIT/OFFSET: limit applies to distinct rows.
SELECT DISTINCT a, b FROM t ORDER BY a, b LIMIT 2;
SELECT DISTINCT a, b FROM t ORDER BY a, b LIMIT 2 OFFSET 2;

-- Values of different storage classes are distinct: 1, '1' and x'31'.
CREATE TABLE m(v);
INSERT INTO m VALUES (1), ('1'), (x'31'), (1), ('1'), (x'31'), (2.5), (2.5);
SELECT DISTINCT v, typeof(v) FROM m ORDER BY v;

-- DISTINCT with an empty table.
CREATE TABLE e(v);
SELECT DISTINCT v FROM e ORDER BY v;

-- DISTINCT on a constant.
SELECT DISTINCT 'k' FROM t;

-- DISTINCT and WHERE together.
SELECT DISTINCT b FROM t WHERE a IS NOT NULL ORDER BY b;

-- DISTINCT with text case: 'A' and 'a' are different under BINARY.
CREATE TABLE c(s TEXT);
INSERT INTO c VALUES ('A'), ('a'), ('A'), ('b');
SELECT DISTINCT s FROM c ORDER BY s;
