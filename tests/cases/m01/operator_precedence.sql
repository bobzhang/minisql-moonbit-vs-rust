-- SQLite operator precedence, from tightest to loosest:
--   unary - +  |  ||  |  * / %  |  + -  |  < <= > >=  |
--   = == != <> IS ISNULL NOTNULL  |  NOT  |  AND  |  OR
-- Binary operators are left-associative.

SELECT 2 + 3 * 4, (2 + 3) * 4, 2 * 3 + 4, 20 - 6 / 2;
SELECT 10 - 4 - 3, 64 / 4 / 2, 17 % 5 * 3, 2 * 7 % 4;
SELECT 7 - 2 * 3 + 1, 1 + 2 * 3 - 4 / 2 % 3;
-- || binds tighter than * and +.
SELECT 2 * 3 || 4, 1 + 2 || 3, '1' || '2' * 2;
-- Unary minus binds tighter than ||.
SELECT -1 || 2, - (1 || 2);
-- Arithmetic binds tighter than comparison.
SELECT 1 + 1 = 2, 2 * 3 > 5, 1 + 2 < 2 + 2;
-- < > bind tighter than = and <>.
SELECT 1 == 2 < 3, 1 = 1 < 2, 0 <> 1 > 2;
-- Chained comparisons are left-associative: (a = b) = c.
SELECT 1 = 1 = 1, 2 = 2 = 2, 1 < 2 < 3, 3 > 2 > 1;
-- IS NULL has the same precedence as =.
SELECT 1 < 2 IS NULL, NULL = 1 IS NULL, 1 + NULL IS NULL;
-- NOT is looser than comparison, tighter than AND/OR.
SELECT NOT 1 = 2, NOT 0 + 1, NOT 1 AND 0, NOT 0 OR 0;
SELECT NOT 1 < 0 AND 1 > 0;
-- AND is tighter than OR.
SELECT 1 OR 1 AND 0, 0 AND 1 OR 1, 0 OR 0 AND 1 OR 1;
SELECT 1 = 1 AND 2 = 2 OR 3 = 4, 1 = 2 AND (2 = 2 OR 3 = 3);
-- Parentheses override everything.
SELECT ((((1 + 2)))) * 3, -(2 + 3) * 2, (1 = 1) + (2 = 2);
-- Precedence in WHERE.
CREATE TABLE t(a INTEGER, b INTEGER, c INTEGER);
INSERT INTO t VALUES (1, 2, 3), (4, 5, 6), (0, 0, 1), (2, 2, 2);
SELECT a FROM t WHERE a = 1 OR b = 5 AND c = 7 ORDER BY a;
SELECT a FROM t WHERE (a = 1 OR b = 5) AND c = 6 ORDER BY a;
SELECT a FROM t WHERE NOT a = 0 AND b + c * 2 > 5 ORDER BY a;
SELECT a, b, c, a + b * c, (a + b) * c, a - b - c FROM t ORDER BY a;
