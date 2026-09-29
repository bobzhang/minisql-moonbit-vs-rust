-- printf/format integer conversions %d %i %u with flags, width and
-- precision.

SELECT printf('%d', 42), printf('%i', 42), printf('%u', 42), printf('%d', -42), printf('%d', 0);
-- Width pads on the left with spaces; '-' pads on the right.
SELECT printf('[%5d]', 42), printf('[%-5d]', 42), printf('[%5d]', -42), printf('[%-5d]', -42);
SELECT printf('[%2d]', 12345), printf('[%1d]', -7);
-- '0' pads with zeros after the sign; ignored with '-'.
SELECT printf('[%05d]', 42), printf('[%05d]', -42), printf('[%-05d]', 42);
-- '+' always shows a sign; ' ' puts a space before non-negative numbers.
SELECT printf('%+d', 42), printf('%+d', -42), printf('%+d', 0), printf('% d', 42), printf('% d', -42);
SELECT printf('[%+5d]', 42), printf('[%-+5d]', 42), printf('[%+05d]', 42), printf('[% 05d]', 7);
-- Precision is the minimum number of digits.
SELECT printf('%.3d', 7), printf('%.3d', -7), printf('%.3d', 12345), printf('[%6.3d]', 7), printf('[%-6.3d]', -7);
-- ',' inserts thousands separators.
SELECT printf('%,d', 1234567), printf('%,d', -1234567), printf('%,d', 999), printf('%,d', 1000), printf('[%,12d]', 1234567);
-- 64-bit limits.
SELECT printf('%d', 9223372036854775807), printf('%d', -9223372036854775808);
-- %u of a negative number shows its unsigned 64-bit value.
SELECT printf('%u', -1), printf('%u', -42);
-- Non-integer arguments are converted: reals truncate, text uses its
-- numeric prefix, NULL is 0.
SELECT printf('%d', 3.99), printf('%d', -3.99), printf('%d', '12abc'), printf('%d', 'abc'), printf('%d', NULL);
SELECT printf('%d', '  7'), printf('%d', x'3132'), printf('%d', 1e20), printf('%d', -1e20);
-- Several conversions in one format.
SELECT printf('%d + %d = %d', 2, 3, 5), printf('%d%d%d', 1, 2, 3);
-- The length modifiers l and ll are accepted and ignored.
SELECT printf('%ld|%lld|%li', 5, 6, 7);
-- format() is an alias of printf().
SELECT format('%05d', 42), format('%+d', 1);
-- Integers from a table.
CREATE TABLE t(n INTEGER);
INSERT INTO t VALUES (1), (-10), (100), (123456), (NULL);
SELECT printf('[%6d] [%-6d] [%06d]', n, n, n) FROM t ORDER BY n;
