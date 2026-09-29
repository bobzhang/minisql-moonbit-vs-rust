-- Which collation a binary comparison uses:
--   1. An explicit COLLATE on the left operand, else on the right operand.
--   2. Otherwise, if the left operand is a column (possibly under unary +
--      or CAST), that column's collation; else if the right operand is a
--      column, its collation.
--   3. Otherwise BINARY.

CREATE TABLE t(id INTEGER, n TEXT COLLATE NOCASE, r TEXT COLLATE RTRIM, b TEXT);
INSERT INTO t VALUES (1, 'abc', 'ABC  ', 'ABC'), (2, 'ABC', 'abc', 'abc'), (3, 'xyz', 'xyz ', 'XYZ');
-- Two columns with different collations: the left column wins.
SELECT id FROM t WHERE n = r ORDER BY id;
SELECT id FROM t WHERE r = n ORDER BY id;
SELECT id FROM t WHERE n = b ORDER BY id;
SELECT id FROM t WHERE b = n ORDER BY id;
SELECT id FROM t WHERE r = b ORDER BY id;
-- Explicit COLLATE beats column collations on either side.
SELECT id FROM t WHERE b = n COLLATE BINARY ORDER BY id;
SELECT id FROM t WHERE r = n COLLATE NOCASE ORDER BY id;
SELECT id FROM t WHERE b COLLATE NOCASE = r ORDER BY id;
-- Left explicit beats right explicit.
SELECT id FROM t WHERE n COLLATE BINARY = b COLLATE NOCASE ORDER BY id;
SELECT id FROM t WHERE n COLLATE RTRIM = r COLLATE NOCASE ORDER BY id;
-- A literal on the left has no collation, so the right column's is used.
SELECT id FROM t WHERE 'ABC' = n ORDER BY id;
SELECT id FROM t WHERE 'abc' = r ORDER BY id;
-- An expression (not a column) has no collation: BINARY unless the other
-- side is a column.
SELECT id FROM t WHERE b || '' = n ORDER BY id;
SELECT id FROM t WHERE n || '' = b || '' ORDER BY id;
SELECT id FROM t WHERE lower(n) = 'ABC' ORDER BY id;
-- An explicit COLLATE inside an expression is carried to its result.
SELECT id FROM t WHERE (b COLLATE NOCASE) = 'abc' ORDER BY id;
-- Literal-only comparisons are BINARY unless COLLATE is given.
SELECT 'a' = 'A', 'a' COLLATE NOCASE = 'A', 'a' = 'A' COLLATE NOCASE;
-- Collation in CASE WHEN comparisons: simple CASE compares base = WHEN.
SELECT id, CASE n WHEN 'ABC' THEN 'hit' ELSE 'miss' END, CASE 'ABC' WHEN n THEN 'hit' ELSE 'miss' END,
  CASE b WHEN 'ABC' THEN 'hit' ELSE 'miss' END FROM t ORDER BY id;
