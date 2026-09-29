-- The target type of CAST is mapped to an affinity with the same rules as
-- column declarations (INT -> INTEGER; CHAR/CLOB/TEXT -> TEXT; BLOB -> BLOB;
-- REAL/FLOA/DOUB -> REAL; otherwise NUMERIC).

SELECT CAST('5' AS FLOATING POINT), typeof(CAST('5' AS FLOATING POINT));
SELECT CAST('5.5' AS POINT), typeof(CAST('5.5' AS POINT));
SELECT CAST(5 AS CHARACTER VARYING(10)), typeof(CAST(5 AS CHARACTER VARYING(10)));
SELECT CAST('5.0' AS STRING), typeof(CAST('5.0' AS STRING));
SELECT CAST(5 AS TEXTBLOB), typeof(CAST(5 AS TEXTBLOB));
SELECT CAST(5 AS BLOBREAL), typeof(CAST(5 AS BLOBREAL));
SELECT CAST('5' AS DOUBLE), typeof(CAST('5' AS DOUBLE));
SELECT CAST('5' AS UNSIGNED BIG INT), typeof(CAST('5' AS UNSIGNED BIG INT));
-- Case-insensitive type names.
SELECT typeof(CAST('5' AS integer)), typeof(CAST(5 AS text)), typeof(CAST(5 AS Real)), typeof(CAST('5' AS blob));
-- CAST gives its result the target affinity in comparisons: a TEXT cast
-- compared with a number converts the number to text.
SELECT CAST(1 AS TEXT) = 1, CAST('1' AS INTEGER) = '1';
-- Nested casts.
SELECT CAST(CAST(CAST('7.9' AS REAL) AS INTEGER) AS TEXT), typeof(CAST(CAST('7.9' AS REAL) AS INTEGER));
-- CAST in WHERE over a column holding mixed types.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, '1'), (2, 1), (3, 1.0), (4, x'31'), (5, '01');
SELECT id FROM t WHERE CAST(v AS INTEGER) = 1 ORDER BY id;
SELECT id FROM t WHERE CAST(v AS TEXT) = '1' ORDER BY id;
-- Syntax error: missing AS and type.
SELECT CAST(1);
SELECT CAST(1 INTEGER);
