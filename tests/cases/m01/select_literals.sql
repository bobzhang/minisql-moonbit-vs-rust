-- Literal values of every storage class and how they print.
SELECT 1, -7, 0, 9223372036854775807;
SELECT 1.5, 100.0, 0.1 + 0.2, 1e20, 1e-5, 0.0001, -2.5e-7;
SELECT 'hello', '', 'it''s';
SELECT NULL, x'00ff', x'';
SELECT TRUE, FALSE;
SELECT typeof(1), typeof(1.0), typeof('a'), typeof(NULL), typeof(x'01');
-- Integer overflow switches to REAL; division by zero is NULL.
SELECT 9223372036854775807 + 1, 5 / 0, 5 % 0, 7 / 2, 7.0 / 2, -7 / 2, -7 % 3;
SELECT 1 +;
SELECT 2 * 3 + 4, 2 + 3 * 4, (2 + 3) * 4, 'a' || 'b' || 1;
