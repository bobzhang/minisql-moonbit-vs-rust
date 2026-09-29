-- A column declared with COLLATE uses that collation in comparisons, even
-- when it appears on the right-hand side of the operator.

CREATE TABLE t(id INTEGER, b TEXT, n TEXT COLLATE NOCASE, r TEXT COLLATE RTRIM, x TEXT COLLATE BINARY);
INSERT INTO t VALUES (1, 'abc', 'abc', 'abc', 'abc'), (2, 'ABC', 'ABC', 'abc  ', 'ABC'), (3, 'Abc ', 'Abc ', ' abc', 'Abc ');
SELECT id FROM t WHERE b = 'abc' ORDER BY id;
SELECT id FROM t WHERE n = 'abc' ORDER BY id;
SELECT id FROM t WHERE 'ABC' = n ORDER BY id;
SELECT id FROM t WHERE r = 'abc' ORDER BY id;
SELECT id FROM t WHERE 'abc' = r ORDER BY id;
SELECT id FROM t WHERE x = 'abc' ORDER BY id;
-- Ordering comparisons use the column collation too.
SELECT id FROM t WHERE n < 'abd' ORDER BY id;
SELECT id FROM t WHERE n > 'ABB' ORDER BY id;
-- An explicit COLLATE overrides the column's collation.
SELECT id FROM t WHERE n = 'abc' COLLATE BINARY ORDER BY id;
SELECT id FROM t WHERE n COLLATE BINARY = 'abc' ORDER BY id;
SELECT id FROM t WHERE b = 'ABC' COLLATE NOCASE ORDER BY id;
-- Unary + and CAST keep the column's collation; other expressions lose it.
SELECT id FROM t WHERE +n = 'ABC' ORDER BY id;
SELECT id FROM t WHERE CAST(n AS TEXT) = 'ABC' ORDER BY id;
SELECT id FROM t WHERE n || '' = 'ABC' ORDER BY id;
SELECT id FROM t WHERE (n) = 'ABC' ORDER BY id;
-- IS, IS NOT, <> and != use the collation as well.
SELECT id FROM t WHERE n IS 'ABC' ORDER BY id;
SELECT id FROM t WHERE n <> 'ABC' ORDER BY id;
-- Declared collation names are case-insensitive.
CREATE TABLE u(s TEXT COLLATE nocase);
INSERT INTO u VALUES ('Mixed');
SELECT s FROM u WHERE s = 'MIXED';
-- A declared collation does not change the stored value.
SELECT n, r FROM t ORDER BY id;
