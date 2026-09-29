-- BETWEEN applies comparison affinity and collation just like the
-- equivalent pair of comparisons (x >= lo AND x <= hi).

CREATE TABLE t(id INTEGER, i INTEGER, s TEXT, n TEXT COLLATE NOCASE);
INSERT INTO t VALUES (1, 5, '5', 'b'), (2, 50, '50', 'B'), (3, 500, '500', 'x');
-- INTEGER column with text bounds: bounds are converted to numbers.
SELECT id FROM t WHERE i BETWEEN '10' AND '100' ORDER BY id;
-- TEXT column with numeric bounds: bounds are converted to text, so the
-- comparison is textual ('500' is between '10' and '6' as text).
SELECT id FROM t WHERE s BETWEEN 10 AND 6 ORDER BY id;
SELECT id FROM t WHERE s BETWEEN 10 AND 100 ORDER BY id;
-- A NOCASE column compares case-insensitively.
SELECT id FROM t WHERE n BETWEEN 'a' AND 'c' ORDER BY id;
SELECT id FROM t WHERE n BETWEEN 'A' AND 'C' ORDER BY id;
-- An explicit COLLATE on the operand applies to both comparisons.
SELECT id FROM t WHERE n COLLATE BINARY BETWEEN 'a' AND 'c' ORDER BY id;
-- An explicit COLLATE on the upper bound only affects x <= hi; x >= lo
-- still uses the column's NOCASE collation.
SELECT id FROM t WHERE n BETWEEN 'a' AND 'c' COLLATE BINARY ORDER BY id;
SELECT id FROM t WHERE n BETWEEN 'C' COLLATE BINARY AND 'z' ORDER BY id;
-- Literal bounds with a literal operand: no conversion.
SELECT '5' BETWEEN 1 AND 10, 5 BETWEEN '1' AND '10';
-- The column's affinity also applies when the column is a bound.
-- 7 >= s compares as text ('7' >= '500' is true); 7 <= '9' is a literal
-- comparison (a number is less than any text).
SELECT id FROM t WHERE 7 BETWEEN s AND '9' ORDER BY id;
-- '20' >= i compares numerically; '20' <= '30' compares as text.
SELECT id FROM t WHERE '20' BETWEEN i AND '30' ORDER BY id;
-- Explicit COLLATE NOCASE on literals.
SELECT 'B' BETWEEN 'a' AND 'c', 'B' COLLATE NOCASE BETWEEN 'a' AND 'c';
-- RTRIM collation ignores trailing spaces at the bounds.
SELECT 'b  ' BETWEEN 'a' AND 'b', 'b  ' COLLATE RTRIM BETWEEN 'a' AND 'b';
