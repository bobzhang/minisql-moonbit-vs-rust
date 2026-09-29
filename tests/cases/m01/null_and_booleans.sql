-- NULL and the boolean literals TRUE/FALSE.

-- TRUE and FALSE are just the integers 1 and 0.
SELECT TRUE, FALSE, typeof(TRUE), typeof(FALSE);
SELECT TRUE + TRUE, FALSE - 1, TRUE * 10;
SELECT true, false, True, fAlSe;
SELECT TRUE = 1, FALSE = 0, TRUE = 2;
-- NULL propagates through arithmetic and concatenation.
SELECT NULL + 1, 1 - NULL, NULL * 0, NULL / 1, 5 % NULL;
SELECT NULL || 'a', 'a' || NULL, NULL || NULL;
SELECT -NULL, +NULL, typeof(-NULL);
-- Comparisons with NULL are NULL.
SELECT NULL = NULL, NULL <> NULL, NULL < 1, 1 >= NULL, NULL = 'a';
-- typeof(NULL) and the keyword in various cases.
SELECT typeof(NULL), typeof(null), typeof(Null);
-- NULL stored in columns of any declared type stays NULL.
CREATE TABLE t(i INTEGER, r REAL, s TEXT, b BLOB, n NUMERIC, u);
INSERT INTO t VALUES (NULL, NULL, NULL, NULL, NULL, NULL);
SELECT i, r, s, b, n, u FROM t;
SELECT typeof(i), typeof(r), typeof(s), typeof(b), typeof(n), typeof(u) FROM t;
-- TRUE/FALSE stored in columns.
CREATE TABLE flags(name TEXT, f BOOLEAN);
INSERT INTO flags VALUES ('yes', TRUE), ('no', FALSE), ('unknown', NULL);
SELECT name, f, typeof(f) FROM flags ORDER BY name;
SELECT name FROM flags WHERE f ORDER BY name;
SELECT name FROM flags WHERE NOT f ORDER BY name;
-- A NULL WHERE condition filters the row out.
SELECT name FROM flags WHERE NULL ORDER BY name;
