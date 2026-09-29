-- LIMIT n, LIMIT n OFFSET m and the comma form LIMIT m, n (offset first).
CREATE TABLE t(n INTEGER);
INSERT INTO t VALUES (1), (2), (3), (4), (5), (6), (7), (8), (9), (10);

SELECT n FROM t ORDER BY n LIMIT 3;
SELECT n FROM t ORDER BY n LIMIT 3 OFFSET 2;
-- Comma form: the FIRST number is the offset.
SELECT n FROM t ORDER BY n LIMIT 2, 3;
SELECT n FROM t ORDER BY n DESC LIMIT 4, 2;

-- LIMIT 0 returns nothing.
SELECT n FROM t ORDER BY n LIMIT 0;
-- Negative LIMIT means no limit.
SELECT n FROM t ORDER BY n LIMIT -1 OFFSET 7;
SELECT n FROM t ORDER BY n LIMIT -5;
-- Negative OFFSET is treated as zero.
SELECT n FROM t ORDER BY n LIMIT 2 OFFSET -3;
-- Comma form with negative count.
SELECT n FROM t ORDER BY n LIMIT 8, -1;

-- Offset past the end.
SELECT n FROM t ORDER BY n LIMIT 5 OFFSET 10;
SELECT n FROM t ORDER BY n LIMIT 5 OFFSET 100;
-- Limit larger than the table.
SELECT n FROM t ORDER BY n DESC LIMIT 1000;

-- LIMIT and OFFSET accept constant expressions.
SELECT n FROM t ORDER BY n LIMIT 1 + 1 OFFSET 2 * 2;
SELECT n FROM t ORDER BY n LIMIT abs(-2) OFFSET length('abc');
-- Text that looks like an integer is accepted.
SELECT n FROM t ORDER BY n LIMIT '2' OFFSET '1';

-- LIMIT after WHERE and ORDER BY.
SELECT n FROM t WHERE n % 2 = 0 ORDER BY n DESC LIMIT 2 OFFSET 1;

-- LIMIT without FROM.
SELECT 42 LIMIT 1;
SELECT 42 LIMIT 0;
SELECT 42 LIMIT 1 OFFSET 1;

-- Non-integer limits are errors.
SELECT n FROM t ORDER BY n LIMIT 'abc';
SELECT n FROM t ORDER BY n LIMIT 2.5;
SELECT n FROM t ORDER BY n LIMIT NULL;
-- LIMIT cannot refer to columns.
SELECT n FROM t ORDER BY n LIMIT n;
