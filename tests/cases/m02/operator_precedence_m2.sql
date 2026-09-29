-- Precedence of the M2 operators. From tightest to loosest:
--   ~ (unary)  |  COLLATE  |  ||  |  * / %  |  + -  |  & | << >>  |
--   < <= > >=  |  = == != <> IS IS NOT IS [NOT] DISTINCT FROM IN LIKE GLOB
--   BETWEEN  |  NOT  |  AND  |  OR

-- || binds tighter than LIKE/GLOB, so the pattern is concatenated first.
SELECT 'abc' LIKE 'a' || '%', 'abc' GLOB 'a' || '*';
-- Arithmetic and bitwise operators bind tighter than BETWEEN and IN.
SELECT 1 + 1 BETWEEN 2 AND 2, 5 & 3 BETWEEN 0 AND 1, 2 * 3 IN (6), 1 << 2 IN (4, 8);
-- Bitwise operators are looser than + and -.
SELECT 1 << 1 + 1, 6 & 3 + 1, 1 | 2 + 4;
-- Comparisons < > are tighter than IN / LIKE / IS.
SELECT 1 < 2 IN (1), 3 > 2 IS 1, 'b' > 'a' LIKE '1';
-- Operators at the '=' level associate left to right.
SELECT 2 BETWEEN 1 AND 3 = 1, 1 = 1 IN (1), 'a' LIKE 'a' = 1, 1 IS 1 IS 1;
-- NOT applies to the whole comparison.
SELECT NOT 1 BETWEEN 2 AND 3, NOT 'abc' LIKE 'x%', NOT 2 IN (1, 2), NOT NULL IS NULL;
-- The AND inside BETWEEN belongs to BETWEEN.
SELECT 2 BETWEEN 1 AND 3 AND 0, 0 OR 2 BETWEEN 1 AND 3;
-- COLLATE binds tighter than || (it attaches to 'b'), and the collation
-- carries through the concatenation to the comparison.
SELECT 'A' || 'b' COLLATE NOCASE = 'aB', ('A' || 'b') COLLATE NOCASE = 'aB';
-- Unary ~ and - bind tightest.
SELECT ~1 + 1, - ~1, ~0 & 5, -1 << 2;
-- CASE, CAST and function calls are atoms.
SELECT CASE WHEN 1 THEN 2 END + 3, CAST('4' AS INTEGER) * 2, abs(-2) BETWEEN 1 AND 3;
-- IS NOT DISTINCT FROM chains with other '=' level operators.
SELECT 1 IS NOT DISTINCT FROM 1 = 1, NULL IS DISTINCT FROM NULL IS 0;
-- Mixed in WHERE.
CREATE TABLE t(id INTEGER, a INTEGER, s TEXT);
INSERT INTO t VALUES (1, 3, 'apple'), (2, 8, 'Banana'), (3, 12, 'cherry'), (4, NULL, NULL);
SELECT id FROM t WHERE a BETWEEN 1 AND 10 AND s LIKE '%an%' OR id = 3 ORDER BY id;
SELECT id FROM t WHERE NOT a IN (3, 12) AND s NOT GLOB 'c*' ORDER BY id;
SELECT id FROM t WHERE a & 4 = 0 OR s IS NULL ORDER BY id;
SELECT id, a + 1 BETWEEN 4 AND 9, s || 'x' LIKE '%ex' FROM t ORDER BY id;
