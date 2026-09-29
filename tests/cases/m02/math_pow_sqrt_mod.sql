-- pow/power, sqrt and mod. These always return REAL (mod too).

SELECT pow(2, 10), power(2, 10), pow(4, -2), pow(2, -1), pow(1.5, 2);
SELECT pow(0, 0), pow(0, 5), pow(1, 1e10), pow(-2, 3), pow(-2, 2), round(pow(2, 0.5), 12);
-- Results that would be NaN are NULL; overflow and division by zero give
-- infinities.
SELECT pow(-8, 1.0 / 3), pow(10, 400), pow(0, -1), pow(-0.5, 0.5);
SELECT typeof(pow(2, 2)), typeof(power(2.0, 2));
-- sqrt.
SELECT sqrt(16), sqrt(2), sqrt(0), sqrt(0.25), sqrt(1e100), sqrt(-1), sqrt(-0.0001);
SELECT typeof(sqrt(16));
-- mod(X, Y) is the floating-point remainder; the sign follows X.
SELECT mod(7, 3), mod(-7, 3), mod(7, -3), mod(-7, -3), mod(7.5, 2), mod(5.5, -2);
SELECT mod(7, 0), mod(0, 5), mod(1e10, 7), typeof(mod(7, 3));
-- Compare with the % operator, which works on integers.
SELECT 7 % 3, mod(7, 3), 7.5 % 2, mod(7.5, 2);
-- NULL and text.
SELECT pow(NULL, 2), pow(2, NULL), sqrt(NULL), mod(NULL, 2), mod(2, NULL);
SELECT pow('2', '3'), sqrt('16'), mod('7', '3'), sqrt(''), pow('x', 2);
-- Over a table.
CREATE TABLE t(a REAL, b REAL);
INSERT INTO t VALUES (2, 3), (9, 2), (-3, 2), (5, -1), (10, 4);
SELECT a, b, pow(a, b), mod(a, b), sqrt(a) FROM t ORDER BY a, b;
-- Wrong number of arguments.
SELECT pow(2);
SELECT sqrt();
SELECT mod(1, 2, 3);
