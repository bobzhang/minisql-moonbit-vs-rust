-- Declared column types: any type name is accepted, including multi-word
-- names and names with one or two (signed) numeric arguments. The type
-- does not restrict what can be stored.

CREATE TABLE t1(
  a INTEGER,
  b VARCHAR(20),
  c DECIMAL(10, 2),
  d UNSIGNED BIG INT,
  e DOUBLE PRECISION,
  f VARYING CHARACTER(255),
  g NATIVE CHARACTER (70),
  h CHARACTER(20),
  i NVARCHAR(100),
  j DATETIME,
  k BOOLEAN,
  l FLOAT,
  m CLOB,
  n BLOB,
  o
);
INSERT INTO t1 VALUES (1, 'x', 3.25, 4, 5.5, 'f', 'g', 'h', 'i', '2024-01-01', 1, 1.5, 'm', x'6e', 'o');
SELECT * FROM t1;
-- Arguments may be signed, and whitespace is flexible.
CREATE TABLE t2(a INT(+5), b NUM(-1, +2), c NUMERIC( 10 ,  5 ), d TEXT(1));
INSERT INTO t2 VALUES (1, 2, 3, 'longer than one');
SELECT * FROM t2;
-- The declared length is not enforced.
CREATE TABLE t3(s VARCHAR(3), n DECIMAL(3, 1));
INSERT INTO t3 VALUES ('abcdefgh', 12345.678);
SELECT s, n FROM t3;
-- Unusual but legal type names.
CREATE TABLE t4(a MY_OWN_TYPE, b SOME OTHER TYPE NAME, c money, d Int);
INSERT INTO t4 VALUES (1, 2, 3, 4);
SELECT * FROM t4;
-- Type names are case-insensitive.
CREATE TABLE t5(a integer, b Text, c rEaL);
INSERT INTO t5 VALUES ('1', 2, '3');
SELECT a, typeof(a), b, typeof(b), c, typeof(c) FROM t5;
-- A column with no type holds anything.
CREATE TABLE t6(anything);
INSERT INTO t6 VALUES (1), ('two'), (3.5), (x'04'), (NULL);
SELECT anything, typeof(anything) FROM t6 ORDER BY anything;
