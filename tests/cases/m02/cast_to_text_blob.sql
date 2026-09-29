-- CAST(x AS TEXT) renders numbers as text (REALs in the output format);
-- CAST(x AS BLOB) takes the bytes of the text form.

SELECT CAST(42 AS TEXT), CAST(-7 AS TEXT), typeof(CAST(42 AS TEXT));
SELECT CAST(1.5 AS TEXT), CAST(100.0 AS TEXT), CAST(-0.25 AS TEXT), CAST(0.001 AS TEXT);
SELECT CAST(123456789.5 AS TEXT), CAST(3.0 AS TEXT);
SELECT CAST(NULL AS TEXT), typeof(CAST(NULL AS TEXT));
-- Blobs become text with the same bytes.
SELECT CAST(x'414243' AS TEXT), CAST(x'' AS TEXT), typeof(CAST(x'' AS TEXT));
SELECT CAST(x'C3A9' AS TEXT);
-- Text types by other names.
SELECT CAST(5 AS VARCHAR(10)), CAST(5 AS CHAR), CAST(5 AS CLOB), typeof(CAST(5 AS NVARCHAR(3)));
-- The length is not enforced.
SELECT CAST('abcdef' AS VARCHAR(2));
-- CAST to TEXT then compare as text.
SELECT CAST(10 AS TEXT) < CAST(9 AS TEXT), CAST(10 AS TEXT) = '10';
-- CAST to BLOB.
SELECT CAST('abc' AS BLOB), CAST(123 AS BLOB), CAST(1.5 AS BLOB), CAST(NULL AS BLOB);
SELECT typeof(CAST('abc' AS BLOB)), typeof(CAST(123 AS BLOB));
SELECT CAST('é' AS BLOB), CAST('' AS BLOB);
-- A blob stays a blob.
SELECT CAST(x'00FF' AS BLOB);
-- Round trip.
SELECT CAST(CAST('hi' AS BLOB) AS TEXT), CAST(CAST(12 AS TEXT) AS INTEGER) + 1;
-- Casting table data.
CREATE TABLE t(id INTEGER, v);
INSERT INTO t VALUES (1, 7), (2, 2.5), (3, 'x'), (4, x'4142'), (5, NULL);
SELECT id, CAST(v AS TEXT), typeof(CAST(v AS TEXT)), CAST(v AS BLOB) FROM t ORDER BY id;
