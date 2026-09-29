-- sign(X): -1, 0 or +1 for negative, zero or positive numeric X; NULL for
-- NULL and for text or blobs that are not numbers. The result is INTEGER.

SELECT sign(5), sign(-5), sign(0), sign(2.5), sign(-0.001), sign(0.0), sign(-0.0);
SELECT typeof(sign(2.5)), typeof(sign(-3)), typeof(sign(0.0));
SELECT sign(9223372036854775807), sign(-9223372036854775808), sign(1e300), sign(-1e999);
SELECT sign(NULL), typeof(sign(NULL));
-- Numeric text is converted; other text gives NULL.
SELECT sign('3'), sign('-1.5'), sign(' 7 '), sign('0'), sign('1e3');
SELECT sign('abc'), sign(''), sign('12abc'), sign('0x5');
-- Blobs give NULL.
SELECT sign(x'01'), sign(x'');
-- In expressions.
SELECT sign(3 - 5), sign(3 - 3), sign(-3 * -5), abs(-7) * sign(-7);
-- In a table.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, 10), (2, -2.5), (3, 0), (4, NULL), (5, '-4'), (6, 'n/a');
SELECT id, sign(v) FROM t ORDER BY id;
SELECT id FROM t WHERE sign(v) = -1 ORDER BY id;
SELECT id FROM t ORDER BY sign(v), id;
-- Wrong number of arguments.
SELECT sign();
SELECT sign(1, 2);
