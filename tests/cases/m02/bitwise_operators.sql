-- Bitwise operators & | ~ on 64-bit two's complement integers.

SELECT 12 & 10, 12 | 10, ~12, ~0, ~-1;
SELECT 5 & 0, 5 | 0, -1 & 255, -1 | 0, 255 & -256;
SELECT typeof(1 & 1), typeof(~1);
SELECT 9223372036854775807 & -1, ~9223372036854775807, -9223372036854775808 | 1;
-- NULL propagates.
SELECT NULL & 1, 1 | NULL, ~NULL;
-- Non-integer operands are converted to integers first (reals truncate).
SELECT 5.7 & 3, -1.5 | 0, ~2.9, 1e20 & 1;
SELECT '12' | 1, '12abc' & 15, 'abc' | 0, x'35' & 7, ~'5';
-- Precedence: & | << >> share one level, tighter than comparisons, looser
-- than + and -. ~ is a unary operator (tightest).
SELECT 2 + 3 & 1, 1 | 2 & 4, 1 & 2 | 4, 6 & 3 = 2, 1 < 2 & 3;
SELECT ~1 + 1, - ~1, ~~5, ~(1 + 1);
-- Bitwise operations on columns.
CREATE TABLE perms(name TEXT, mask INTEGER);
INSERT INTO perms VALUES ('read', 4), ('write', 2), ('exec', 1), ('all', 7), ('none', 0), ('unknown', NULL);
SELECT name FROM perms WHERE mask & 2 ORDER BY name;
SELECT name FROM perms WHERE mask & 4 = 0 ORDER BY name;
SELECT name, mask | 8, mask & ~1 FROM perms ORDER BY name;
SELECT name FROM perms WHERE (mask | 1) = mask ORDER BY name;
