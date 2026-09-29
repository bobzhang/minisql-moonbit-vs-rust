-- round(X [, Y]): X rounded to Y digits after the decimal point (default 0).
-- The result is always REAL (for non-NULL X). Halfway cases round away from
-- zero.

SELECT round(2.4), round(2.5), round(2.6), round(-2.5), round(-2.4), round(0.5), round(-0.5);
SELECT round(1.5), round(3.5), round(4.5);
SELECT round(3.14159, 2), round(3.14159, 3), round(3.14159, 0), round(-3.14159, 1);
SELECT typeof(round(5)), round(5), round(-5), typeof(round(2.5));
-- Exact halfway values at other positions.
SELECT round(0.125, 2), round(0.375, 2), round(-0.125, 2), round(1.25, 1), round(-1.25, 1);
-- Values that look halfway but are not exactly representable round by
-- their true binary value.
SELECT round(2.675, 2), round(1.005, 2), round(0.45, 1);
-- A negative digit count is treated as 0.
SELECT round(1234.5678, -2), round(15.5, -1);
-- The digit count is truncated to an integer.
SELECT round(1.2345, 2.9), round(1.2345, '3');
-- Large digit counts leave the value unchanged.
SELECT round(1.2345, 400), round(123.456, 20);
-- Large values.
SELECT round(1e300), round(-1e300, 2), round(4503599627370497.0), round(9223372036854775807);
-- NULL.
SELECT round(NULL), round(1.5, NULL), round(NULL, 2);
-- Text is converted.
SELECT round('2.5'), round('3.14159', 2), round('abc'), round('7x');
-- From a table.
CREATE TABLE t(v REAL);
INSERT INTO t VALUES (1.005), (2.5), (-2.5), (0.0), (123.456), (-0.049);
SELECT v, round(v), round(v, 1), round(v, 2) FROM t ORDER BY v;
-- Wrong number of arguments.
SELECT round();
SELECT round(1, 2, 3);
