-- Comparison affinity: when a column with INTEGER, REAL or NUMERIC affinity
-- is compared with a TEXT value that has no affinity (a literal), NUMERIC
-- affinity is applied to the text first - if it looks like a number it is
-- compared as a number.

CREATE TABLE t(id INTEGER, i INTEGER, r REAL, n NUMERIC);
INSERT INTO t VALUES (1, 10, 10.0, 10), (2, 2, 2.5, 2), (3, -1, -1.0, -1);
SELECT id FROM t WHERE i = '10';
SELECT id FROM t WHERE i = '10.0';
SELECT id FROM t WHERE i = ' 10 ';
SELECT id FROM t WHERE i = '1e1';
SELECT id FROM t WHERE r = '2.5';
SELECT id FROM t WHERE n = '-1';
-- Ordering comparisons become numeric (as text, '10' < '9').
SELECT id FROM t WHERE i < '9' ORDER BY id;
SELECT id FROM t WHERE i > '3' ORDER BY id;
SELECT id FROM t WHERE r >= '2.5' ORDER BY id;
-- Text that is not a number stays text, and every number is less than it.
SELECT id FROM t WHERE i < 'abc' ORDER BY id;
SELECT id FROM t WHERE i = '10abc';
SELECT id FROM t WHERE i > '' ORDER BY id;
-- The literal may be on either side.
SELECT id FROM t WHERE '10' = i;
SELECT id FROM t WHERE '9' > i ORDER BY id;
-- Without the column (literal vs literal) there is no conversion.
SELECT 10 = '10', '10' = 10, 10 < '9';
-- The same rules in the SELECT list.
SELECT id, i = '10', i < '9', r = '2.50', n <> '2' FROM t ORDER BY id;
-- Values stored as TEXT in a numeric column (not convertible) still compare
-- as text.
INSERT INTO t VALUES (4, 'ten', 'ten', 'ten');
SELECT id FROM t WHERE i = 'ten';
SELECT id FROM t WHERE i > 1000 ORDER BY id;
SELECT id FROM t WHERE n < 'z' ORDER BY id;
