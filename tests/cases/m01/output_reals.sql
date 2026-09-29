-- How REAL values are printed (SPEC §2.3): shortest round-trip digits,
-- fixed notation for -5 < E < 16, otherwise scientific with a signed,
-- at-least-two-digit exponent. Always a '.' in the mantissa.

SELECT 1.0, 2.5, -2.5, 100.0, 0.25, 123456.789;
-- Fixed notation down to 1e-4.
SELECT 0.001, 0.0001, 0.00012345;
-- Scientific notation from 1e-5 down.
SELECT 0.00001, 0.000012345, 1e-10, 1.5e-100;
-- Fixed notation up to (but excluding) 1e16.
SELECT 1e15, 1000000000000000.0, 9999999999999998.0, 123456789012345.6;
-- Scientific notation from 1e16 up.
SELECT 1e16, 1.5e16, 12345678901234567890.0, 1e100;
-- Extremes of the double range.
SELECT 1.7976931348623157e308, -1.7976931348623157e308, 5e-324, 2.2250738585072014e-308;
-- Negative zero prints as 0.0.
SELECT 0.0, -0.0, 0.0 * -1;
-- Overflow to infinity.
SELECT 1e308 * 10, -1e308 * 10, 1e999, -1e999;
-- inf - inf is NaN, which SQLite turns into NULL.
SELECT 1e999 - 1e999;
-- Values that are not exactly representable print their shortest form.
SELECT 0.1, 0.2, 0.1 + 0.2, 1.1 * 1.1, 1.0 / 3;
SELECT 2.0 / 3, 10.0 / 4, 1e15 + 0.3;
-- Integral reals keep a fractional part.
SELECT 3.0, -7.0, 1e0, 12e2, 2.5e1;
SELECT typeof(1e0), typeof(12e2), typeof(3.0);
-- Reals stored in a table.
CREATE TABLE t(r REAL);
INSERT INTO t VALUES (1.5), (1e20), (-0.000001), (42), (3.14159);
SELECT r FROM t ORDER BY r;
