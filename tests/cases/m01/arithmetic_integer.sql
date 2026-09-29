-- Integer arithmetic: + - * / % on INTEGER operands stays INTEGER.
-- Division truncates toward zero; % takes the sign of the left operand.

SELECT 1 + 2, 10 - 3, 6 * 7, 20 / 4, 20 % 6;
SELECT typeof(1 + 2), typeof(6 * 7), typeof(20 / 4), typeof(20 % 6);
-- Integer division truncates toward zero.
SELECT 7 / 2, -7 / 2, 7 / -2, -7 / -2;
SELECT 1 / 3, 2 / 3, -1 / 3, 0 / 5;
-- Remainder takes the sign of the dividend.
SELECT 7 % 3, -7 % 3, 7 % -3, -7 % -3;
SELECT 0 % 3, 3 % 3, 2 % 3;
-- Large values.
SELECT 9223372036854775807 / 2, 9223372036854775807 % 10;
SELECT 3037000499 * 3037000499;
SELECT 1000000000 * 1000000000;
SELECT -9223372036854775807 - 1;
-- Chained operators associate left to right.
SELECT 100 - 10 - 1, 100 / 10 / 2, 2 * 3 * 4, 100 % 7 % 3;
SELECT 10 - 2 + 3, 10 / 2 * 3, 7 % 4 * 2;
-- Arithmetic on columns.
CREATE TABLE t(a INTEGER, b INTEGER);
INSERT INTO t VALUES (10, 3), (-10, 3), (10, -3), (0, 7), (7, 7);
SELECT a, b, a + b, a - b, a * b, a / b, a % b FROM t ORDER BY a, b;
SELECT a * 2 + b FROM t ORDER BY a * 2 + b;
