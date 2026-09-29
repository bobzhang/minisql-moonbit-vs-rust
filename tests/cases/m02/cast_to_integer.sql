-- CAST(x AS INTEGER): text uses its longest integer prefix (0 if none);
-- reals are truncated toward zero and saturate at the 64-bit limits.

SELECT CAST(42 AS INTEGER), CAST(-7 AS INTEGER), CAST(NULL AS INTEGER);
SELECT typeof(CAST(NULL AS INTEGER)), typeof(CAST('5' AS INTEGER));
-- Reals truncate toward zero.
SELECT CAST(1.9 AS INTEGER), CAST(-1.9 AS INTEGER), CAST(0.5 AS INTEGER), CAST(-0.5 AS INTEGER);
SELECT CAST(1e18 AS INTEGER), CAST(123456.789 AS INTEGER);
-- Reals beyond the range saturate.
SELECT CAST(1e20 AS INTEGER), CAST(-1e20 AS INTEGER), CAST(1e999 AS INTEGER), CAST(-1e999 AS INTEGER);
-- Text: leading/trailing spaces ignored, then the longest integer prefix.
SELECT CAST('123' AS INTEGER), CAST('  -45  ' AS INTEGER), CAST('+7' AS INTEGER);
SELECT CAST('12abc' AS INTEGER), CAST('abc' AS INTEGER), CAST('' AS INTEGER), CAST('-' AS INTEGER);
-- A decimal point or exponent ends the integer prefix.
SELECT CAST('1.9' AS INTEGER), CAST('-1.9' AS INTEGER), CAST('1e3' AS INTEGER), CAST('.5' AS INTEGER);
-- Hex text is not recognized.
SELECT CAST('0x1F' AS INTEGER);
-- Text integers beyond 64 bits saturate.
SELECT CAST('9223372036854775807' AS INTEGER), CAST('9223372036854775808' AS INTEGER), CAST('-9223372036854775809' AS INTEGER);
SELECT CAST('99999999999999999999' AS INTEGER);
-- Blobs are read as text.
SELECT CAST(x'3132' AS INTEGER), CAST(x'' AS INTEGER), CAST(x'2D35' AS INTEGER);
-- INT, BIGINT etc. are INTEGER casts too.
SELECT CAST('3.7' AS INT), CAST(3.7 AS BIGINT), CAST('8' AS TINYINT), typeof(CAST('8' AS SMALLINT));
-- Casting table data.
CREATE TABLE t(v);
INSERT INTO t VALUES (3.99), ('17 apples'), (x'39'), (NULL), (-0.1), ('  8  ');
SELECT v, CAST(v AS INTEGER), typeof(CAST(v AS INTEGER)) FROM t ORDER BY v;
SELECT v FROM t WHERE CAST(v AS INTEGER) = 3;
