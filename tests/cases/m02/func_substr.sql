-- substr(X, Y [, Z]) / substring(X, Y [, Z]): the substring of X starting at
-- position Y (1-based) with length Z. Negative Y counts from the end;
-- negative Z takes the |Z| characters before position Y. Positions count
-- characters for text and bytes for blobs.

SELECT substr('hello', 1), substr('hello', 2), substr('hello', 5), substr('hello', 6);
SELECT substr('hello', 1, 2), substr('hello', 2, 3), substr('hello', 4, 10), substr('hello', 3, 0);
-- Negative start counts from the end.
SELECT substr('hello', -1), substr('hello', -3), substr('hello', -3, 2), substr('hello', -5, 1);
-- Start before the beginning.
SELECT substr('hello', -10), substr('hello', -10, 3), substr('hello', -6, 3);
-- Position 0 is just before the first character.
SELECT substr('hello', 0), substr('hello', 0, 2), substr('hello', 0, 1);
-- Negative length takes characters before the start position.
SELECT substr('hello', 3, -2), substr('hello', 2, -1), substr('hello', 1, -1), substr('hello', -1, -2);
-- substring is the same function.
SELECT substring('hello', 2, 3), substring('hello', -2);
-- Non-ASCII: characters, not bytes.
SELECT substr('日本語テキスト', 2, 3), substr('héllo', 2, 1), substr('😀ab', 2);
-- Blobs: bytes.
SELECT substr(x'0102030405', 2, 2), substr(x'0102030405', -1), typeof(substr(x'01', 1));
-- Numbers are converted to text.
SELECT substr(12345, 2, 3), substr(-1.5, 1, 2), typeof(substr(123, 1));
-- Non-integer positions and lengths are truncated.
SELECT substr('hello', 1.9, 2.9), substr('hello', '2', '2');
-- NULL in any argument gives NULL.
SELECT substr(NULL, 1), substr('abc', NULL), substr('abc', 1, NULL);
-- In a table.
CREATE TABLE t(id INTEGER, code TEXT);
INSERT INTO t VALUES (1, 'AB-1234'), (2, 'XY-99'), (3, 'Z'), (4, NULL);
SELECT id, substr(code, 1, 2), substr(code, 4), substr(code, -2) FROM t ORDER BY id;
SELECT id FROM t WHERE substr(code, 1, 1) = 'X';
-- Wrong number of arguments.
SELECT substr('abc');
SELECT substr('abc', 1, 2, 3);
