-- exp, ln, log (base 10, or log(B, X) with base B), log10 and log2.
-- Non-positive arguments to logarithms give NULL.

SELECT exp(0), ln(1), log(1), log10(1), log2(1);
SELECT round(exp(1), 12), round(exp(-1), 12), round(exp(2.5), 10);
SELECT round(log(100), 12), round(log10(1000), 12), log2(8), log2(1024), round(log10(0.001), 12), log2(0.5);
SELECT round(ln(10), 12), round(ln(exp(3)), 12), round(log(2), 12), round(log2(3), 12);
-- Two-argument log(B, X) is the logarithm of X in base B.
SELECT round(log(10, 100), 12), round(log(2, 8), 12), round(log(2, 1024), 12), round(log(3, 81), 12), round(log(0.5, 4), 12);
-- Out of domain.
SELECT ln(0), ln(-1), log(0), log10(-5), log2(0), log(-2, 8), log(2, -8), log(1, 10);
-- Overflow and underflow of exp.
SELECT exp(1000), exp(-1000);
-- Integer arguments give REAL results.
SELECT typeof(exp(0)), typeof(log(100)), typeof(ln(1));
-- NULL and text.
SELECT exp(NULL), ln(NULL), log(NULL, 2), log(2, NULL), log10('100'), log2('abc');
-- Round trips.
SELECT round(exp(ln(42)), 10), round(log(exp(1.5)) * ln(10), 10);
-- Over a table.
CREATE TABLE t(v REAL);
INSERT INTO t VALUES (0.1), (1.0), (10.0), (1000.0), (-1.0), (0.0);
SELECT v, round(ln(v), 10), round(log10(v), 10), round(log2(v), 10) FROM t ORDER BY v;
-- Wrong number of arguments.
SELECT ln();
SELECT log(1, 2, 3);
SELECT exp(1, 2);
