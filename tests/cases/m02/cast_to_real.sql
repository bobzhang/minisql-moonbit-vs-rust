-- CAST(x AS REAL): numbers become REAL; text uses its longest numeric prefix
-- (0.0 if none); blobs are read as text.

SELECT CAST(5 AS REAL), CAST(-5 AS REAL), CAST(0 AS REAL), CAST(1.5 AS REAL);
SELECT typeof(CAST(5 AS REAL)), typeof(CAST(NULL AS REAL)), CAST(NULL AS REAL);
SELECT CAST(9223372036854775807 AS REAL), CAST(-9223372036854775808 AS REAL);
SELECT CAST('3.25' AS REAL), CAST('  -2.5  ' AS REAL), CAST('.5' AS REAL), CAST('5.' AS REAL);
SELECT CAST('1e3' AS REAL), CAST('1.5E-3' AS REAL), CAST('-1e+2' AS REAL);
-- Longest numeric prefix.
SELECT CAST('12abc' AS REAL), CAST('1.5.6' AS REAL), CAST('2e' AS REAL), CAST('3e+' AS REAL);
SELECT CAST('abc' AS REAL), CAST('' AS REAL), CAST('-' AS REAL), CAST('.' AS REAL);
-- Overflowing text becomes infinity.
SELECT CAST('1e400' AS REAL), CAST('-1e400' AS REAL);
-- Blobs.
SELECT CAST(x'312E35' AS REAL), CAST(x'' AS REAL);
-- FLOAT and DOUBLE are REAL casts.
SELECT CAST('7' AS FLOAT), CAST(7 AS DOUBLE), CAST('7' AS DOUBLE PRECISION), typeof(CAST(1 AS FLOAT));
-- Casting table data.
CREATE TABLE t(v);
INSERT INTO t VALUES (1), ('2.5kg'), (x'33'), (NULL), ('none'), (4.75);
SELECT v, CAST(v AS REAL) FROM t ORDER BY v;
SELECT CAST(v AS REAL) / 2 FROM t WHERE v = 1;
