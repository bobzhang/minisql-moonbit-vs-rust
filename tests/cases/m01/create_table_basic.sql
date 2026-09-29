-- CREATE TABLE followed by INSERT and SELECT.

CREATE TABLE t(a, b, c);
SELECT * FROM t;
INSERT INTO t VALUES (1, 'one', 1.5);
SELECT * FROM t;
INSERT INTO t VALUES (2, 'two', 2.5), (3, 'three', NULL);
SELECT * FROM t ORDER BY a;
SELECT c, b, a FROM t ORDER BY a DESC;
-- A table with a single column.
CREATE TABLE single(x INTEGER);
INSERT INTO single VALUES (10);
INSERT INTO single VALUES (20);
SELECT x FROM single ORDER BY x;
-- Many columns.
CREATE TABLE wide(c1, c2, c3, c4, c5, c6, c7, c8, c9, c10);
INSERT INTO wide VALUES (1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
SELECT * FROM wide;
SELECT c10, c1, c5 FROM wide;
-- Several tables coexist independently.
CREATE TABLE a1(v TEXT);
CREATE TABLE a2(v TEXT);
INSERT INTO a1 VALUES ('in a1');
INSERT INTO a2 VALUES ('in a2');
SELECT v FROM a1;
SELECT v FROM a2;
-- Keywords are case-insensitive.
create table lower_case(x integer);
Insert Into lower_case Values (7);
sElEcT x FrOm lower_case;
-- Errors: empty column list, trailing comma, missing parentheses.
CREATE TABLE bad1();
CREATE TABLE bad2(a, b,);
CREATE TABLE bad3;
