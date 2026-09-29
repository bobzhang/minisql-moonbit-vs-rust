-- The comparison operators = == != <> < <= > >= on values of the same
-- storage class. Results are 1 (true), 0 (false) or NULL.

SELECT 1 = 1, 1 == 1, 1 = 2, 1 == 2;
SELECT 1 != 2, 1 <> 2, 1 != 1, 1 <> 1;
SELECT 1 < 2, 2 < 1, 1 < 1, 1 <= 1, 2 <= 1;
SELECT 2 > 1, 1 > 2, 1 > 1, 1 >= 1, 1 >= 2;
SELECT typeof(1 = 1), typeof(1 < 2);
-- Negative numbers and zero.
SELECT -1 < 0, -5 < -4, 0 = -0, -0.0 = 0.0, -0.0 < 0.0;
-- Reals.
SELECT 1.5 < 2.5, 0.1 + 0.2 = 0.3, 0.5 = 0.50, 1e3 = 1000.0;
-- Text uses binary (byte-wise) comparison: uppercase sorts before lowercase,
-- a prefix sorts before the longer string.
SELECT 'abc' = 'abc', 'abc' = 'ABC', 'abc' < 'abd', 'B' < 'a', 'a' < 'ab';
SELECT '' < 'a', '' = '', 'a ' = 'a', 'Z' < 'a', '10' < '9';
-- UTF-8 byte order: non-ASCII sorts after ASCII.
SELECT 'é' > 'z', 'ä' < 'é', '中' > 'é';
-- Blobs compare with memcmp; a shorter prefix is smaller.
SELECT x'01' < x'02', x'01' < x'0100', x'' < x'00', x'ff' > x'00ff', x'AB' = x'ab';
-- Comparisons with NULL are NULL.
SELECT 1 = NULL, NULL != 1, NULL < NULL, 'a' >= NULL;
-- Comparisons in WHERE on columns of matching type.
CREATE TABLE t(n INTEGER, s TEXT);
INSERT INTO t VALUES (1, 'apple'), (2, 'Banana'), (3, 'cherry'), (4, 'apple pie'), (5, NULL);
SELECT n FROM t WHERE n > 2 ORDER BY n;
SELECT n FROM t WHERE n <> 3 ORDER BY n;
SELECT n FROM t WHERE s = 'apple' ORDER BY n;
SELECT n FROM t WHERE s < 'b' ORDER BY n;
SELECT n FROM t WHERE s >= 'apple' ORDER BY n;
SELECT n FROM t WHERE s != 'apple' ORDER BY n;
