-- Unary minus and plus. Unary plus is a no-op that keeps the value and its
-- type (even TEXT and BLOB); unary minus converts to a number.

SELECT -1, - 1, -(-1), - -1, -(1 + 2);
SELECT +1, +-1, -+1, +(+1), - + - 3;
SELECT -1.5, +1.5, -(-1.5), -0.0;
-- Unary plus leaves text and blobs untouched.
SELECT +'abc', typeof(+'abc'), +'12', typeof(+'12');
SELECT +x'01', typeof(+x'01');
-- Unary minus converts text to a number.
SELECT -'12', typeof(-'12'), -'1.5', typeof(-'1.5');
SELECT -'abc', typeof(-'abc'), -'', -'3x';
SELECT -x'35';
-- NULL.
SELECT -NULL, +NULL;
-- Unary minus binds tighter than binary operators.
SELECT -2 * 3, -2 + 3, 2 - -3, 2 * -3, -2 || 'x';
-- Unary operators on columns.
CREATE TABLE t(a INTEGER, s TEXT);
INSERT INTO t VALUES (5, '7'), (-3, 'x'), (0, '-2');
SELECT a, -a, +a, -s, +s, typeof(+s) FROM t ORDER BY a;
SELECT a FROM t ORDER BY -a;
