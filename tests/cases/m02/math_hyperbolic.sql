-- Hyperbolic functions: sinh cosh tanh asinh acosh atanh. Inexact results
-- are rounded to 12 places.

SELECT sinh(0), cosh(0), tanh(0), asinh(0), acosh(1), atanh(0);
SELECT round(sinh(1), 12), round(cosh(1), 12), round(tanh(1), 12);
SELECT round(sinh(-1), 12), round(cosh(-1), 12), round(tanh(-1), 12);
SELECT round(asinh(1), 12), round(acosh(2), 12), round(atanh(0.5), 12), round(asinh(-2), 12);
-- tanh saturates at +/-1.
SELECT tanh(100), tanh(-100);
-- Out of domain gives NULL; atanh(+/-1) is infinite.
SELECT acosh(0.5), acosh(-1), atanh(2), atanh(1), atanh(-1);
-- Overflow gives infinity.
SELECT sinh(1000), cosh(-1000), sinh(-1000);
-- Results are REAL.
SELECT typeof(sinh(0)), typeof(acosh(1));
-- NULL and text.
SELECT sinh(NULL), cosh('x'), round(tanh('0.5'), 12);
-- Identities: cosh^2 - sinh^2 = 1, inverse round trips.
SELECT round(cosh(2) * cosh(2) - sinh(2) * sinh(2), 9), round(asinh(sinh(1.5)), 12), round(atanh(tanh(0.25)), 12);
-- Over a table.
CREATE TABLE t(x REAL);
INSERT INTO t VALUES (-2.0), (-0.5), (0.0), (0.5), (2.0);
SELECT x, round(sinh(x), 10), round(cosh(x), 10), round(tanh(x), 10) FROM t ORDER BY x;
-- Wrong number of arguments.
SELECT cosh(1, 2);
