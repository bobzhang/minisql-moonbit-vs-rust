-- abs(X): absolute value. Integers stay INTEGER, reals stay REAL, text and
-- blobs are converted to REAL, NULL gives NULL. abs() of the most negative
-- integer is an "integer overflow" error.

SELECT abs(5), abs(-5), abs(0), typeof(abs(-5));
SELECT abs(2.5), abs(-2.5), abs(-0.0), typeof(abs(-2.5));
SELECT abs(NULL), typeof(abs(NULL));
SELECT abs(9223372036854775807), abs(-9223372036854775807);
SELECT abs(-1e300), abs(-1e999);
-- Text and blobs become REAL (even when they look like integers).
SELECT abs('-3'), typeof(abs('-3')), abs('-3.5'), abs('4'), abs(' -7 ');
SELECT abs('abc'), typeof(abs('abc')), abs('12abc'), abs('');
SELECT abs(x'2D33'), typeof(abs(x'2D33'));
-- Integer overflow.
SELECT abs(-9223372036854775808);
SELECT abs(-9223372036854775807 - 1);
-- A REAL just past the integer range is fine.
SELECT abs(-9223372036854775808.0);
-- abs in expressions and WHERE.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, -10), (2, 3), (3, -0.5), (4, NULL), (5, '-8'), (6, 0);
SELECT id, abs(v), typeof(abs(v)) FROM t ORDER BY id;
SELECT id FROM t WHERE abs(v) > 2 ORDER BY id;
SELECT id FROM t ORDER BY abs(v), id;
-- Function names are case-insensitive.
SELECT ABS(-1), Abs(-2);
-- Wrong number of arguments.
SELECT abs();
SELECT abs(1, 2);
