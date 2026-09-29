-- trim(X [, Y]), ltrim(X [, Y]), rtrim(X [, Y]) remove characters in Y
-- (default: spaces only) from both ends / the left / the right of X.

SELECT '[' || trim('  a b  ') || ']', '[' || ltrim('  a b  ') || ']', '[' || rtrim('  a b  ') || ']';
SELECT trim(''), trim('   '), ltrim('x'), rtrim('x');
-- Only spaces by default: tabs and newlines stay.
SELECT '[' || trim(char(9) || 'a' || char(9)) || ']' = '[' || char(9) || 'a' || char(9) || ']';
-- A set of characters to remove (order does not matter).
SELECT trim('xxhixx', 'x'), ltrim('xxhixx', 'x'), rtrim('xxhixx', 'x');
SELECT trim('abcHELLOcba', 'abc'), trim('abcHELLOcba', 'cba'), trim('123abc321', '0123456789');
SELECT ltrim('aabbcc', 'ab'), rtrim('aabbcc', 'bc'), trim('aaaa', 'a');
-- An empty set removes nothing.
SELECT trim('  x  ', '') = '  x  ';
-- Non-ASCII characters in the set.
SELECT trim('ééaéé', 'é'), ltrim('中中文', '中'), rtrim('abc😀😀', '😀');
-- NULL.
SELECT trim(NULL), trim('a', NULL), ltrim(NULL, 'a'), rtrim('a', NULL);
-- Numbers and blobs are converted to text.
SELECT trim(123, '1'), rtrim(1.5, '5'), ltrim(-7, '-'), typeof(trim(5)), trim(x'204120');
-- In a table.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, '  padded  '), (2, '--dashes--'), (3, 'none'), (4, '   '), (5, NULL);
SELECT id, '[' || trim(s) || ']', '[' || trim(s, '-') || ']', length(ltrim(s)), length(rtrim(s)) FROM t ORDER BY id;
SELECT id FROM t WHERE trim(s) = '' ORDER BY id;
-- Wrong number of arguments.
SELECT trim();
SELECT ltrim('a', 'b', 'c');
