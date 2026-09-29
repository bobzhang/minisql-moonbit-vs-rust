-- printf %x %X (hex), %o (octal) and %c (character).

SELECT printf('%x', 255), printf('%X', 255), printf('%o', 8), printf('%x', 0), printf('%o', 0);
SELECT printf('%x', 3735928559), printf('%X', 3735928559), printf('%o', 511);
-- Negative numbers are shown as unsigned 64-bit values.
SELECT printf('%x', -1), printf('%X', -2), printf('%o', -1);
-- '#' adds a 0x / 0X / 0 prefix (not for zero).
SELECT printf('%#x', 255), printf('%#X', 255), printf('%#o', 8), printf('%#x', 0), printf('%#o', 0);
-- Width, '0' and '-' flags.
SELECT printf('[%8x]', 255), printf('[%-8x]', 255), printf('[%08x]', 255), printf('[%08X]', 48879);
SELECT printf('[%#8x]', 255), printf('[%-#8X]', 255), printf('[%#8o]', 8);
-- Precision is the minimum number of digits.
SELECT printf('[%.4x]', 10), printf('[%5.3x]', 10), printf('[%#.3x]', 10), printf('[%.3o]', 8);
-- Non-integers are converted first.
SELECT printf('%x', 3.7), printf('%x', '255'), printf('%x', '0x10'), printf('%x', NULL), printf('%X', 'ff');
-- %c prints the first character of the argument's text form.
SELECT printf('%c', 'abc'), printf('%c', 'Z'), printf('%c', 65), printf('%c', 'é!');
-- Width applies to %c.
SELECT printf('[%3c]', 'x'), printf('[%-3c]', 'y'), printf('[%c%c%c]', 'a', 'b', 'c');
-- Hex digits from a table.
CREATE TABLE t(n INTEGER);
INSERT INTO t VALUES (0), (9), (10), (15), (16), (4096);
SELECT n, printf('%x|%X|%o|%#x|%04x', n, n, n, n, n) FROM t ORDER BY n;
