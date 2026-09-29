-- SELECT * and table.* expand to all columns in declaration order.

CREATE TABLE t(a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES (1, 'x', 1.5), (2, 'y', 2.5);
SELECT * FROM t ORDER BY a;
SELECT t.* FROM t ORDER BY a;
-- Mixing * with other expressions.
SELECT *, a * 10 FROM t ORDER BY a;
SELECT a + 100, * FROM t ORDER BY a;
SELECT *, * FROM t ORDER BY a;
SELECT t.*, t.a FROM t ORDER BY a;
-- With a table alias, use alias.*.
SELECT x.* FROM t AS x ORDER BY x.a;
SELECT x.*, x.b FROM t x ORDER BY x.a DESC;
-- The original name is hidden by the alias.
SELECT t.* FROM t AS x;
-- * without FROM is an error.
SELECT *;
-- Unknown table in table.*.
SELECT nosuch.* FROM t;
-- * on an empty table returns no rows.
CREATE TABLE empty(p, q);
SELECT * FROM empty;
SELECT empty.* FROM empty;
-- * on a single-column table.
CREATE TABLE one(v TEXT);
INSERT INTO one VALUES ('only');
SELECT * FROM one;
SELECT *, v || '!' FROM one;
