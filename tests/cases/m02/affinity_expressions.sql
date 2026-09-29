-- Expressions have no affinity, except: a plain column reference (also
-- inside parentheses), CAST(x AS type) (the type's affinity), and unary +
-- which REMOVES affinity from a column.

CREATE TABLE t(id INTEGER, i INTEGER, s TEXT);
INSERT INTO t VALUES (1, 5, '5'), (2, 50, '50'), (3, 7, '07');
-- A plain column has affinity; wrapping it in parentheses keeps it.
SELECT id FROM t WHERE i = '5';
SELECT id FROM t WHERE (i) = '5';
-- Unary + removes the affinity: no conversion, INTEGER vs TEXT is unequal.
SELECT id FROM t WHERE +i = '5';
SELECT id FROM t WHERE +s = 5;
-- Arithmetic and concatenation results have no affinity.
SELECT id FROM t WHERE i + 0 = '5';
SELECT id FROM t WHERE s || '' = 5;
SELECT id FROM t WHERE i * 1 = 5;
-- CAST gives the result the target type's affinity.
SELECT id FROM t WHERE CAST(i AS TEXT) = 5;
SELECT id FROM t WHERE CAST(s AS INTEGER) = '7' ORDER BY id;
SELECT id FROM t WHERE CAST(s AS NUMERIC) = '5' ORDER BY id;
-- An expression compared with a column: the column's affinity applies to
-- the expression's value.
SELECT id FROM t WHERE i = '4' + 1;
SELECT id FROM t WHERE s = 2 + 3;
SELECT id FROM t WHERE s = 7 ORDER BY id;
-- CASE and function results have no affinity.
SELECT id FROM t WHERE CASE WHEN 1 THEN i END = '5';
SELECT id FROM t WHERE coalesce(i, 0) = '5';
-- Ordering comparisons show the difference between numeric and textual.
SELECT id FROM t WHERE s < 6 ORDER BY id;
SELECT id FROM t WHERE +s < 6 ORDER BY id;
SELECT id FROM t WHERE CAST(s AS INTEGER) < 6 ORDER BY id;
