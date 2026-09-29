-- Arithmetic on TEXT and BLOB operands: the value is converted to a number
-- using its longest numeric prefix (0 if none). The result is INTEGER when
-- the text is an integer, REAL when it looks like a real.

SELECT '3' + 4, '3.5' * 2, '10' / '4', '10' % '4';
SELECT typeof('3' + 4), typeof('3.0' + 4), '3.0' + 4;
-- Leading and trailing spaces are ignored.
SELECT '  7' * 2, '7  ' * 2, ' 7 ' + 0;
-- Signs and decimal points.
SELECT '-5' + 0, '+5' + 0, '.5' + 0, '5.' + 0, '-.5' + 0;
-- Exponents make it REAL.
SELECT '1e3' + 0, '1.5e2' + 0, typeof('1e3' + 0), '2E-2' + 0;
-- Longest numeric prefix.
SELECT '12abc' + 1, '3.5xyz' + 0, '1e' + 0, '1e+' + 0, '7-3' + 0;
-- No numeric prefix gives 0.
SELECT 'abc' + 1, '' + 0, 'x5' + 0, '-' + 0, '.' + 0;
-- Hex text is not recognized: only the leading 0 counts.
SELECT '0x1A' + 0;
-- Integers beyond 64 bits become REAL.
SELECT '9223372036854775807' + 0, '9223372036854775808' + 0, '-9223372036854775808' + 0;
SELECT typeof('9223372036854775807' + 0), typeof('9223372036854775808' + 0);
SELECT '99999999999999999999' + 0;
-- Blobs are interpreted as their bytes as text.
SELECT x'35' + 1, x'3335' * 2, x'' + 1, x'00' + 1, typeof(x'35' + 0);
-- Unary minus converts too.
SELECT -'12', -'1.5', -'abc', typeof(-'abc'), -x'35';
-- Text columns in arithmetic.
CREATE TABLE t(s TEXT);
INSERT INTO t VALUES ('10'), ('2.5'), ('abc'), ('4x'), (' 8 ');
SELECT s, s + 1, s * 2, typeof(s + 1) FROM t ORDER BY s;
