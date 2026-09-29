-- typeof(x) returns 'null', 'integer', 'real', 'text' or 'blob'.

SELECT typeof(NULL), typeof(0), typeof(-1), typeof(0.0), typeof(1e10);
SELECT typeof(''), typeof('0'), typeof(x''), typeof(x'00');
SELECT typeof(TRUE), typeof(0x10), typeof(9223372036854775807), typeof(9223372036854775808);
-- The result of an expression.
SELECT typeof(1 + 1), typeof(1 + 1.0), typeof(1 / 2), typeof(1.0 / 2), typeof(1 / 0);
SELECT typeof('a' || 'b'), typeof(1 || 2), typeof(x'01' || x'02');
SELECT typeof(1 = 1), typeof(NULL = 1), typeof(NOT 'x'), typeof(1 IS NULL);
SELECT typeof(-'5'), typeof(-'5.5'), typeof(+'5'), typeof('5' * 1), typeof('5.5' * 1);
-- typeof returns text.
SELECT typeof(typeof(1)), typeof(1) || '!';
-- typeof of columns reflects the stored class after affinity.
CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n NUMERIC);
INSERT INTO t VALUES ('1', '1', 1, '1', '1.0');
INSERT INTO t VALUES (1.5, 'x', x'00', 2, '1.5');
SELECT typeof(i), typeof(r), typeof(s), typeof(b), typeof(n) FROM t ORDER BY typeof(i);
-- typeof in WHERE.
SELECT i FROM t WHERE typeof(i) = 'real';
SELECT r FROM t WHERE typeof(r) = 'text';
-- Case-insensitive function name.
SELECT TYPEOF(1), TypeOf('a');
