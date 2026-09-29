-- How INTEGER values are printed: plain decimal with a leading '-' for
-- negatives, across the full 64-bit range.

SELECT 0, 1, -1, 42, -42;
SELECT 1000000, 123456789012, -987654321098;
SELECT 9223372036854775807, -9223372036854775807;
-- The most negative integer is written as a negated literal.
SELECT -9223372036854775808;
SELECT typeof(-9223372036854775808);
-- Arithmetic that stays inside the 64-bit range stays INTEGER.
SELECT 9223372036854775806 + 1, -9223372036854775807 - 1;
SELECT typeof(9223372036854775806 + 1), typeof(-9223372036854775807 - 1);
SELECT 4294967296 * 4294967295;
SELECT 2147483647 + 1, -2147483648 - 1;
-- Leading zeros in a literal are ignored.
SELECT 007, 0010, -0;
SELECT typeof(-0), typeof(007);
-- Integers stored in a table print the same way.
CREATE TABLE t(v INTEGER);
INSERT INTO t VALUES (5), (-5), (9223372036854775807), (-9223372036854775808), (0);
SELECT v, typeof(v) FROM t ORDER BY v;
