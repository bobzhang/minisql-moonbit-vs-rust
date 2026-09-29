-- ceil/ceiling, floor and trunc. INTEGER input gives the same INTEGER back;
-- REAL input gives a REAL result.

SELECT ceil(1.2), ceil(-1.2), ceil(1.0), ceiling(1.5), ceiling(-1.5);
SELECT floor(1.8), floor(-1.8), floor(-1.0), floor(0.5), floor(-0.5);
SELECT trunc(1.8), trunc(-1.8), trunc(0.999), trunc(-0.999), trunc(2.0);
-- Integers pass through unchanged with INTEGER type.
SELECT ceil(5), floor(-7), trunc(9223372036854775807), floor(-9223372036854775808);
SELECT typeof(ceil(5)), typeof(floor(5)), typeof(trunc(5)), typeof(ceil(5.5)), typeof(trunc(5.5));
-- Negative results that are zero print as 0.0.
SELECT ceil(-0.5), trunc(-0.3);
-- Huge reals are already integral.
SELECT ceil(1e300), floor(-1e300), trunc(1e20), ceil(1e999);
-- NULL gives NULL; numeric text is converted (integers stay integers),
-- other text and blobs give NULL.
SELECT ceil(NULL), floor(NULL), trunc(NULL);
SELECT ceil('1.5'), floor(' 3 '), trunc('4.7'), ceil('2'), typeof(ceil('2'));
SELECT floor('abc'), ceil(x'31'), trunc('1abc');
-- Compared with CAST, which truncates to INTEGER.
SELECT trunc(-2.7), CAST(-2.7 AS INTEGER), floor(-2.7), round(-2.7);
-- Over a table.
CREATE TABLE t(v);
INSERT INTO t VALUES (2.5), (-2.5), (3), (-0.1), (NULL), ('7.9');
SELECT v, ceil(v), floor(v), trunc(v) FROM t ORDER BY v;
-- Wrong number of arguments.
SELECT ceil();
SELECT floor(1, 2);
