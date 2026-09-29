-- x IN (v1, v2, ...) and NOT IN with literal lists.

SELECT 1 IN (1, 2, 3), 4 IN (1, 2, 3), 1 NOT IN (1, 2, 3), 4 NOT IN (1, 2, 3);
SELECT 'b' IN ('a', 'b'), 'B' IN ('a', 'b'), x'01' IN (x'01', x'02');
-- A single-element list.
SELECT 5 IN (5), 5 IN (6);
-- Integer and real compare numerically.
SELECT 1 IN (1.0), 2.5 IN (1, 2.5), 3 IN (3.0000001);
-- Text and numbers are different values.
SELECT 1 IN ('1'), '1' IN (1), '1' IN ('1', 2);
-- The list may contain expressions and mixed types.
SELECT 6 IN (1 + 1, 2 * 3), 'ab' IN ('a' || 'b', 1, NULL, x'00');
-- An empty list is allowed: IN () is false and NOT IN () is true.
SELECT 1 IN (), 1 NOT IN (), 'x' IN ();
-- Duplicate values in the list.
SELECT 2 IN (2, 2, 2);
-- IN in WHERE.
CREATE TABLE t(id INTEGER, color TEXT, n INTEGER);
INSERT INTO t VALUES (1, 'red', 10), (2, 'green', 20), (3, 'blue', 30), (4, 'red', 40), (5, NULL, NULL);
SELECT id FROM t WHERE color IN ('red', 'blue') ORDER BY id;
SELECT id FROM t WHERE color NOT IN ('red', 'blue') ORDER BY id;
SELECT id FROM t WHERE n IN (10, 30, 50) ORDER BY id;
SELECT id FROM t WHERE n * 2 IN (40, 80) ORDER BY id;
SELECT id FROM t WHERE id IN (n / 10, 5) ORDER BY id;
SELECT id, color IN ('red') FROM t ORDER BY id;
-- IN has the same precedence as '='.
SELECT 1 IN (1) = 1, 2 IN (1, 2) AND 3 IN (3);
-- Keywords are case-insensitive.
SELECT 1 in (1), 1 Not In (2);
-- Syntax error: missing parentheses.
SELECT 1 IN 1, 2;
