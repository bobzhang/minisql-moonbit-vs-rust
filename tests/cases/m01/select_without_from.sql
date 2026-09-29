-- SELECT without FROM evaluates the expressions once and returns one row.

SELECT 1;
SELECT 1, 2, 3;
SELECT 'a', 1.5, NULL, x'00';
SELECT 1 + 1, 'x' || 'y', -5, NOT 0;
SELECT typeof(1 + 1.0), typeof('a' || 1), typeof(NULL + 1);
-- SELECT ALL is the same as SELECT.
SELECT ALL 1, 2;
SELECT ALL 'all';
-- A WHERE clause without FROM filters the single row.
SELECT 'kept' WHERE 1;
SELECT 'dropped' WHERE 0;
SELECT 'dropped' WHERE NULL;
SELECT 'kept' WHERE 2 > 1 AND 'a' < 'b';
-- ORDER BY without FROM is allowed (one row, nothing to sort).
SELECT 3 ORDER BY 1 + 1;
-- A column reference without FROM is an error.
SELECT a;
SELECT t.a;
-- Parentheses around a result expression.
SELECT (1), ((2)), (((3 + 4)));
-- Long expression lists.
SELECT 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20;
