-- printf %e %E (scientific) and %g %G (shortest of %e/%f, trailing zeros
-- removed).

SELECT printf('%e', 12345.678), printf('%.2e', 12345.678), printf('%E', 0.000123), printf('%.0e', 5.0);
SELECT printf('%e', 0.0), printf('%e', -1.5), printf('%e', 1.0), printf('%.3e', 1e100), printf('%e', 1e-300);
-- Width and flags.
SELECT printf('[%12.3e]', -1.5), printf('[%-12.2e]', 1.5), printf('[%+.1e]', 1.5), printf('[%012.2e]', 1.5);
-- Halfway cases round away from zero.
SELECT printf('%.0e', 15.0), printf('%.0e', 25.0), printf('%.1e', 0.25);
-- Integers and text are converted.
SELECT printf('%e', 100), printf('%.1e', '2500'), printf('%E', NULL);
-- %g uses %e when the exponent is < -4 or >= precision (default 6).
SELECT printf('%g', 100000.0), printf('%g', 1000000.0), printf('%g', 0.0001), printf('%g', 0.00001);
SELECT printf('%g', 123.456), printf('%g', 123456.7), printf('%g', 1234567.0), printf('%g', 0.5);
SELECT printf('%g', 0.0), printf('%g', 100), printf('%g', -2.5), printf('%g', 1e100), printf('%G', 1e-10);
-- Precision is the number of significant digits.
SELECT printf('%.3g', 3.14159), printf('%.2g', 0.000123456), printf('%.10g', 1e15), printf('%.2g', 150.0);
-- Trailing zeros are removed unless '#' is given.
SELECT printf('%g', 1.5), printf('%g', 2.0), printf('%#g', 2.0), printf('%#.3g', 1.0), printf('%#g', 100000.0);
-- Width.
SELECT printf('[%10g]', 3.25), printf('[%-10g]', 3.25), printf('[%010g]', -3.25);
-- Infinity.
SELECT printf('%e', 1e999), printf('%g', -1e999);
-- From a table.
CREATE TABLE t(x REAL);
INSERT INTO t VALUES (0.000012345), (1.5), (1234567.0), (-98.76);
SELECT printf('%g|%e|%.2G', x, x, x) FROM t ORDER BY x;
