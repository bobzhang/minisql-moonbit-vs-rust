-- Arithmetic with REAL operands: any REAL operand makes the result REAL.

SELECT 1.5 + 1, 1 + 1.5, 2.5 * 2, 5 - 2.5, 7.0 / 2, 7 / 2.0;
SELECT typeof(1.5 + 1), typeof(2.5 * 2), typeof(7 / 2.0), typeof(3 * 1.0);
SELECT 3 * 1.0, 4.0 / 2, 0.5 + 0.5;
-- Floating point rounding shows up in the output.
SELECT 0.1 + 0.2, 0.1 * 3, 1.1 * 1.1, 3.3 - 1.1;
SELECT 1.0 / 3, 2.0 / 3, 10.0 / 3;
-- Real overflow gives infinities.
SELECT 1e308 + 1e308, -1e308 - 1e308, 1e200 * 1e200;
-- Tiny results.
SELECT 1e-200 * 1e-200, 1e-300 / 1e10;
-- Negative zero results print as 0.0.
SELECT -1.0 * 0, 0.0 * -5, -0.0 + 0.0;
-- Division of reals by zero is NULL, like integers.
SELECT 1.5 / 0, 1.5 / 0.0, 0.0 / 0.0;
-- Real remainder: both operands are converted to INTEGER first, result REAL.
SELECT 5.5 % 3, 7 % 2.9, 7.9 % 2, -7.9 % 2, typeof(5.5 % 3);
SELECT 5 % 0.5, 10.0 % 4;
-- Mixed arithmetic in a table with REAL affinity.
CREATE TABLE m(x REAL, y INTEGER);
INSERT INTO m VALUES (1.5, 2), (2.25, 4), (-0.5, 3), (10, 5);
SELECT x, y, x * y, x / y, x + y, typeof(x * y) FROM m ORDER BY x;
