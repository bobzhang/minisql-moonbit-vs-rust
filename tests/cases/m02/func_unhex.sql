-- unhex(X [, Y]): decode a hex string into a blob. Returns NULL if X is not
-- valid hex (odd digit count, bad characters). Characters in Y may appear
-- between pairs of hex digits and are ignored.

SELECT unhex('414243'), unhex('4a4B'), unhex(''), typeof(unhex(''));
SELECT unhex('00FF'), unhex('deadbeef');
-- Invalid input gives NULL.
SELECT unhex('4'), unhex('zz'), unhex('41 42'), unhex('0x41');
SELECT unhex(NULL), unhex('41', NULL);
-- Separators.
SELECT unhex('41-42-43', '-'), unhex('41 42', ' '), unhex('41:42 43', ': ');
-- Separators may be repeated between pairs...
SELECT unhex('41--42', '-'), unhex('41 - 42', ' -');
-- ...but not inside a pair.
SELECT unhex('4-1', '-'), unhex('4 1', ' ');
-- A number argument is converted to text first.
SELECT unhex(4142), unhex(12);
-- The result is a blob; CAST makes it text.
SELECT CAST(unhex('68656C6C6F') AS TEXT), CAST(unhex('C3A9') AS TEXT);
-- From a table.
CREATE TABLE t(id INTEGER, h TEXT);
INSERT INTO t VALUES (1, '616263'), (2, 'ABC'), (3, 'ab cd'), (4, NULL), (5, '');
SELECT id, unhex(h), unhex(h, ' ') FROM t ORDER BY id;
SELECT id FROM t WHERE unhex(h) IS NULL ORDER BY id;
-- Wrong number of arguments.
SELECT unhex();
SELECT unhex('41', ' ', 'x');
