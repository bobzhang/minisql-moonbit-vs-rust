-- printf %f: fixed-point with 6 digits after the point by default.

SELECT printf('%f', 3.14159), printf('%f', 1.0), printf('%f', 0.0), printf('%f', -2.5);
SELECT printf('%.2f', 3.14159), printf('%.0f', 3.14159), printf('%.1f', 0.25), printf('%.3f', 2.0);
SELECT printf('%.10f', 0.5), printf('%.4f', 1.0 / 3);
-- Width, '-' and '0' flags.
SELECT printf('[%10.3f]', 3.14159), printf('[%-10.1f]', 3.14159), printf('[%010.2f]', -3.14159), printf('[%08.3f]', 2.5);
-- '+' and ' ' flags.
SELECT printf('%+.1f', 2.5), printf('%+.1f', -2.5), printf('% .1f', 2.5), printf('% .1f', -2.5);
-- '#' keeps the decimal point when the precision is 0.
SELECT printf('%.0f', 2.0), printf('%#.0f', 2.0);
-- Rounding of values that are exactly halfway: SQLite rounds away from zero.
SELECT printf('%.0f', 0.5), printf('%.0f', 1.5), printf('%.0f', 2.5), printf('%.0f', -0.5), printf('%.0f', -2.5);
SELECT printf('%.2f', 0.125), printf('%.1f', 0.75), printf('%.2f', 1.375);
-- Values that are not exactly representable round according to their true
-- binary value (2.675 is really 2.67499999...).
SELECT printf('%.2f', 2.675), printf('%.1f', 0.45), printf('%.1f', 0.35);
-- Integers and numeric text are converted.
SELECT printf('%f', 5), printf('%.2f', '1.005e1'), printf('%.1f', '12abc'), printf('%.1f', 'abc'), printf('%f', NULL);
-- Large and small magnitudes.
SELECT printf('%.2f', 123456789.125), printf('%.3f', 0.0005), printf('%.2f', -0.001);
SELECT printf('%.1f', 1e15), printf('%f', 1e-7);
-- ',' groups the integer part.
SELECT printf('%,.2f', 1234567.891), printf('%,.0f', 1000.0);
-- Infinities.
SELECT printf('%f', 1e999), printf('%f', -1e999), printf('[%6.1f]', 1e999);
-- From a table.
CREATE TABLE t(x REAL);
INSERT INTO t VALUES (1.5), (-0.25), (100.0), (2.0 / 3);
SELECT printf('[%8.2f]', x) FROM t ORDER BY x;
