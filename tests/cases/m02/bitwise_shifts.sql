-- Shift operators << and >>: >> is an arithmetic (sign-preserving) shift;
-- shifting by 64 or more gives 0 (or -1 for a negative value shifted right);
-- a negative shift amount shifts the other way.

SELECT 1 << 0, 1 << 1, 1 << 10, 3 << 4, 1024 >> 3, 1023 >> 3;
SELECT 1 << 62, 1 << 63, 3 << 62, typeof(1 << 63);
SELECT 1 << 64, 1 << 100, 255 >> 64, -1 >> 64, -256 >> 100;
-- Arithmetic right shift keeps the sign.
SELECT -16 >> 2, -1 >> 1, -9223372036854775808 >> 1, -9223372036854775808 >> 63;
SELECT -1 << 1, -1 << 63, -5 << 2;
-- Negative shift amounts reverse the direction.
SELECT 1 >> -1, 8 << -2, -8 << -1, 1 << -64, -1 << -64;
-- Huge shift amounts.
SELECT 2 << 9223372036854775807, 2 >> 9223372036854775807, -2 >> 9223372036854775807;
-- Non-integer operands are converted.
SELECT 1.9 << 1, -1.9 << 1, '3' << '2', 'x' << 1, 1 << 2.9;
SELECT NULL << 1, 1 >> NULL;
-- Precedence: shifts bind looser than + and -.
SELECT 1 << 2 + 1, (1 << 2) + 1, 1 | 2 << 1, 16 >> 1 >> 1, 1 << 3 & 12;
-- Shifts on columns.
CREATE TABLE b(n INTEGER, s INTEGER);
INSERT INTO b VALUES (1, 4), (100, 2), (-100, 2), (7, 0), (5, -1), (NULL, 1);
SELECT n, s, n << s, n >> s FROM b ORDER BY n, s;
