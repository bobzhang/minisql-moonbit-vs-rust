-- The postfix COLLATE operator selects BINARY, NOCASE or RTRIM for a
-- comparison.

-- BINARY: exact byte comparison (the default).
SELECT 'abc' = 'ABC', 'abc' = 'ABC' COLLATE BINARY, 'a' < 'B', 'a' < 'B' COLLATE BINARY;
-- NOCASE folds ASCII A-Z to a-z only.
SELECT 'abc' = 'ABC' COLLATE NOCASE, 'a' < 'B' COLLATE NOCASE, 'Zebra' > 'apple' COLLATE NOCASE;
SELECT 'é' = 'É' COLLATE NOCASE, 'straße' = 'STRASSE' COLLATE NOCASE, '[' < 'a' COLLATE NOCASE;
-- RTRIM ignores trailing spaces (only spaces, only at the end).
SELECT 'abc' = 'abc   ' COLLATE RTRIM, 'abc  ' = 'abc' COLLATE RTRIM, ' abc' = 'abc' COLLATE RTRIM;
SELECT 'abc' = 'ABC' COLLATE RTRIM, 'abc' = 'abc' || char(9) COLLATE RTRIM;
-- COLLATE on the left operand or the right operand.
SELECT 'abc' COLLATE NOCASE = 'ABC', 'abc' = 'ABC' COLLATE NOCASE;
-- If both operands have an explicit COLLATE, the left one wins.
SELECT 'a' COLLATE NOCASE = 'A' COLLATE BINARY, 'a' COLLATE BINARY = 'A' COLLATE NOCASE;
-- Collation names are case-insensitive.
SELECT 'x' = 'X' COLLATE nocase, 'x' = 'X' COLLATE NoCase, 'x ' = 'x' COLLATE rtrim;
-- COLLATE does not change the value itself.
SELECT 'AbC' COLLATE NOCASE, typeof(1 COLLATE NOCASE), 1 COLLATE NOCASE + 1;
-- COLLATE binds tighter than any binary operator: here it applies to 'b'
-- only, and the concatenation result keeps it.
SELECT 'a' || 'B' COLLATE NOCASE = 'AB';
-- COLLATE only matters for text; numbers compare numerically.
SELECT 10 = 10.0 COLLATE NOCASE, 2 < 10 COLLATE NOCASE;
-- Comparison operators of every kind use it.
SELECT 'a' <> 'A' COLLATE NOCASE, 'a' IS 'A' COLLATE NOCASE, 'a' IS NOT 'A' COLLATE NOCASE, 'b' >= 'B' COLLATE NOCASE;
-- Collation in WHERE.
CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, 'apple'), (2, 'Apple'), (3, 'APPLE '), (4, 'banana'), (5, NULL);
SELECT id FROM t WHERE s = 'apple' ORDER BY id;
SELECT id FROM t WHERE s = 'apple' COLLATE NOCASE ORDER BY id;
SELECT id FROM t WHERE s COLLATE RTRIM = 'APPLE' ORDER BY id;
SELECT id FROM t WHERE s < 'b' COLLATE NOCASE ORDER BY id;
SELECT id FROM t WHERE s COLLATE NOCASE <> 'APPLE' ORDER BY id;
-- An unknown collation is an error when it is needed for a comparison.
SELECT 'a' = 'a' COLLATE nosuch;
