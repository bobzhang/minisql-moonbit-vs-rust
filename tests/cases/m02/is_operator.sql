-- IS and IS NOT: like = and <> except that NULLs compare as equal to each
-- other, and the result is never NULL.

SELECT 1 IS 1, 1 IS 2, 1 IS NOT 1, 1 IS NOT 2;
SELECT NULL IS NULL, NULL IS 1, 1 IS NULL, NULL IS NOT NULL, NULL IS NOT 1;
SELECT typeof(NULL IS 1), typeof(1 IS 1);
-- Same comparison rules as '=': integer vs real numerically, no conversion
-- between text and numbers for literals.
SELECT 1 IS 1.0, '1' IS 1, 'a' IS 'a', 'a' IS 'A', x'01' IS x'01', x'01' IS '1';
-- Comparing expressions that may be NULL.
SELECT 1 / 0 IS NULL, (1 / 0) IS (2 / 0), 1 + 1 IS 2;
-- IS has the same precedence as '='.
SELECT 1 IS 1 = 1, 2 > 1 IS 1;
-- Rows with NULLs.
CREATE TABLE t(id INTEGER, a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 1, 1), (2, 1, 2), (3, NULL, 1), (4, 1, NULL), (5, NULL, NULL);
SELECT id, a = b, a IS b, a <> b, a IS NOT b FROM t ORDER BY id;
SELECT id FROM t WHERE a IS b ORDER BY id;
SELECT id FROM t WHERE a IS NOT b ORDER BY id;
SELECT id FROM t WHERE a IS 1 ORDER BY id;
SELECT id FROM t WHERE b IS NOT 1 ORDER BY id;
-- Column affinity applies to IS just as it does to '='.
CREATE TABLE u(i INTEGER, s TEXT);
INSERT INTO u VALUES (5, '5');
SELECT i IS '5', s IS 5, i IS s, '5' IS i FROM u;
-- NOT with IS.
SELECT NOT (NULL IS NULL), NOT NULL IS NULL;
