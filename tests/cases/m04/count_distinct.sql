-- count(DISTINCT x) counts distinct non-NULL values. Numerically equal
-- integers and reals are the same value; TEXT and numbers are different.
CREATE TABLE t(v);
INSERT INTO t VALUES (1), (1), (1.0), (2), ('1'), ('1'), (NULL), (NULL), (x'01'), (x'01'), ('a'), ('A');
SELECT count(DISTINCT v), count(v), count(*) FROM t;
SELECT count(DISTINCT typeof(v)) FROM t;
SELECT count(DISTINCT v) FROM t WHERE typeof(v) IN ('integer', 'real');
SELECT count(DISTINCT v) FROM t WHERE typeof(v) = 'text';

-- DISTINCT on an expression.
SELECT count(DISTINCT lower(v)) FROM t WHERE typeof(v) = 'text';
SELECT count(DISTINCT v * 0) FROM t WHERE typeof(v) IN ('integer', 'real');

-- The column's collation is used: NOCASE treats 'a' and 'A' as equal.
CREATE TABLE c(s TEXT COLLATE NOCASE, r TEXT COLLATE RTRIM, b TEXT);
INSERT INTO c VALUES ('a', 'x', 'a'), ('A', 'x ', 'A'), ('b', 'y', 'b'), ('B', 'y  ', 'b');
SELECT count(DISTINCT s), count(DISTINCT r), count(DISTINCT b) FROM c;
-- COLLATE inside the argument overrides it.
SELECT count(DISTINCT s COLLATE BINARY), count(DISTINCT b COLLATE NOCASE) FROM c;

-- Empty and all-NULL inputs.
CREATE TABLE e(v);
SELECT count(DISTINCT v) FROM e;
INSERT INTO e VALUES (NULL);
SELECT count(DISTINCT v) FROM e;

-- Per group.
CREATE TABLE g(k TEXT, v INTEGER);
INSERT INTO g VALUES ('a', 1), ('a', 1), ('a', 2), ('b', 3), ('b', 3), ('c', NULL);
SELECT k, count(DISTINCT v), count(v), count(*) FROM g GROUP BY k ORDER BY k;

-- count(DISTINCT *) is a syntax error; DISTINCT takes exactly one argument.
SELECT count(DISTINCT *) FROM t;
SELECT count(DISTINCT v, v) FROM t;
