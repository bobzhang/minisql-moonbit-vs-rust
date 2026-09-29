-- Division and remainder by zero yield NULL, never an error.

SELECT 1 / 0, 1 % 0, 0 / 0, 0 % 0, -1 / 0;
SELECT typeof(1 / 0), typeof(1 % 0);
SELECT 1.0 / 0, 1 / 0.0, 1.5 % 0, 1 % 0.0;
-- A divisor that truncates to 0 in % also yields NULL.
SELECT 5 % 0.5, 5 % -0.9;
-- Text operands that convert to zero.
SELECT 5 / '0', 5 / 'abc', 5 % '', 5 / '0.0';
-- NULL divided by zero is still NULL.
SELECT NULL / 0, 0 / NULL;
-- Division by zero inside larger expressions.
SELECT 1 + 1 / 0, (1 / 0) IS NULL, (1 / 0) = NULL;
SELECT 10 / (5 - 5), 10 % (2 * 0);
-- Per-row division by zero in a table.
CREATE TABLE t(a INTEGER, b INTEGER);
INSERT INTO t VALUES (10, 2), (10, 0), (7, -1), (0, 0), (-9, 4);
SELECT a, b, a / b, a % b FROM t ORDER BY a, b;
SELECT a FROM t WHERE a / b IS NULL ORDER BY a;
SELECT a FROM t WHERE a / b > 0 ORDER BY a;
