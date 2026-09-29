-- INSERT INTO t VALUES (...), multi-row VALUES, and explicit column lists.

CREATE TABLE t(a INTEGER, b TEXT, c REAL);
INSERT INTO t VALUES (1, 'one', 1.0);
INSERT INTO t VALUES (2, 'two', 2.0), (3, 'three', 3.0), (4, 'four', 4.0);
SELECT * FROM t ORDER BY a;
-- Column list in table order.
INSERT INTO t (a, b, c) VALUES (5, 'five', 5.0);
-- Column list in a different order.
INSERT INTO t (c, a, b) VALUES (6.0, 6, 'six');
-- A subset of columns: the others become NULL.
INSERT INTO t (a) VALUES (7);
INSERT INTO t (b, a) VALUES ('eight', 8);
SELECT a, b, c FROM t WHERE a >= 5 ORDER BY a;
-- Multi-row insert with a column list.
INSERT INTO t (b, a) VALUES ('nine', 9), ('ten', 10);
SELECT a, b, c FROM t WHERE a > 8 ORDER BY a;
-- Expressions in VALUES are evaluated.
INSERT INTO t VALUES (10 + 1, 'ele' || 'ven', 22 / 2.0);
INSERT INTO t VALUES (-(-12), 'twelve', 1e1 + 2);
SELECT a, b, c FROM t WHERE a > 10 ORDER BY a;
-- Duplicate rows are allowed.
CREATE TABLE d(x INTEGER);
INSERT INTO d VALUES (1), (1), (1);
INSERT INTO d VALUES (1);
SELECT x FROM d ORDER BY x;
-- Keyword case and whitespace.
insert into d(x)values(2);
INSERT   INTO   d   (  x  )   VALUES   (  3  ) ;
SELECT x FROM d ORDER BY x;
-- NULLs everywhere.
INSERT INTO t VALUES (NULL, NULL, NULL);
SELECT a, b, c FROM t WHERE a IS NULL;
