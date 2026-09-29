-- ORDER BY with ASC/DESC on single columns of one type.

CREATE TABLE t(id INTEGER, name TEXT, score REAL);
INSERT INTO t VALUES (3, 'carol', 7.5), (1, 'alice', 9.0), (4, 'dave', 6.25), (2, 'bob', 8.0), (5, 'eve', 10.0);
SELECT id FROM t ORDER BY id;
SELECT id FROM t ORDER BY id ASC;
SELECT id FROM t ORDER BY id DESC;
SELECT name FROM t ORDER BY name;
SELECT name FROM t ORDER BY name DESC;
SELECT name, score FROM t ORDER BY score;
SELECT name, score FROM t ORDER BY score DESC;
-- The sort key need not be selected.
SELECT name FROM t ORDER BY score;
-- Qualified column in ORDER BY.
SELECT t.name FROM t ORDER BY t.id DESC;
SELECT x.name FROM t AS x ORDER BY x.score;
-- ORDER BY together with WHERE.
SELECT name FROM t WHERE score > 7 ORDER BY name DESC;
-- Keywords are case-insensitive.
select name from t order by id desc;
SELECT name FROM t ORDER BY id Asc;
-- Negative numbers and zero.
CREATE TABLE n(v INTEGER);
INSERT INTO n VALUES (0), (-5), (5), (-100), (100), (1);
SELECT v FROM n ORDER BY v;
SELECT v FROM n ORDER BY v DESC;
-- Text sorts by bytes: uppercase before lowercase, digits before letters.
CREATE TABLE s(v TEXT);
INSERT INTO s VALUES ('b'), ('B'), ('a'), ('A'), ('10'), ('9'), ('_'), (' '), ('ab'), ('aB');
SELECT v FROM s ORDER BY v;
SELECT v FROM s ORDER BY v DESC;
-- Sorting an empty table returns nothing.
CREATE TABLE e(v INTEGER);
SELECT v FROM e ORDER BY v;
-- Unknown column in ORDER BY is an error.
SELECT id FROM t ORDER BY nosuch;
