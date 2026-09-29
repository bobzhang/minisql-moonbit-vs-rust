-- x BETWEEN lo AND hi is lo <= x AND x <= hi (inclusive). NOT BETWEEN negates.

SELECT 2 BETWEEN 1 AND 3, 1 BETWEEN 1 AND 3, 3 BETWEEN 1 AND 3, 0 BETWEEN 1 AND 3, 4 BETWEEN 1 AND 3;
SELECT 2 NOT BETWEEN 1 AND 3, 0 NOT BETWEEN 1 AND 3;
-- Bounds in the wrong order match nothing.
SELECT 2 BETWEEN 3 AND 1;
-- Reals and mixed numeric types.
SELECT 1.5 BETWEEN 1 AND 2, 2 BETWEEN 1.5 AND 2.5, 2.5 BETWEEN 2.5 AND 2.5;
-- Text uses text ordering (BINARY).
SELECT 'b' BETWEEN 'a' AND 'c', 'B' BETWEEN 'a' AND 'c', 'abc' BETWEEN 'ab' AND 'abd';
-- NULL handling follows AND of two comparisons.
SELECT NULL BETWEEN 1 AND 2, 1 BETWEEN NULL AND 2, 5 BETWEEN NULL AND 2, 1 BETWEEN 0 AND NULL, 5 BETWEEN 6 AND NULL;
SELECT 5 NOT BETWEEN NULL AND 2, 1 NOT BETWEEN NULL AND 2;
-- BETWEEN binds tighter than AND: the first AND belongs to BETWEEN.
SELECT 2 BETWEEN 1 AND 3 AND 1, 2 BETWEEN 1 AND 3 AND 0;
-- Arithmetic in operands.
SELECT 5 BETWEEN 2 + 2 AND 3 * 2, 1 + 1 BETWEEN 2 AND 2;
-- BETWEEN in WHERE.
CREATE TABLE t(id INTEGER, v INTEGER, s TEXT);
INSERT INTO t VALUES (1, 5, 'apple'), (2, 10, 'banana'), (3, 15, 'cherry'), (4, NULL, 'date'), (5, 20, NULL), (6, -5, 'Apple');
SELECT id FROM t WHERE v BETWEEN 5 AND 15 ORDER BY id;
SELECT id FROM t WHERE v NOT BETWEEN 5 AND 15 ORDER BY id;
SELECT id FROM t WHERE s BETWEEN 'b' AND 'd' ORDER BY id;
SELECT id FROM t WHERE s NOT BETWEEN 'b' AND 'd' ORDER BY id;
SELECT id FROM t WHERE id BETWEEN v / 5 AND v ORDER BY id;
SELECT id, v BETWEEN 0 AND 12 FROM t ORDER BY id;
-- Cross-class: numbers are below text, so text is never BETWEEN two numbers.
SELECT 'x' BETWEEN 1 AND 100, 50 BETWEEN 1 AND 'a';
