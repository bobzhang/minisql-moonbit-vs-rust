-- How non-boolean values behave as conditions: numeric values are true when
-- non-zero; text and blobs are converted to a number first (so 'abc' is
-- false and '1abc' is true); NULL is neither.

SELECT 2 AND 1, -1 AND 1, 0.5 AND 1, 0.0 AND 1, 0.0 OR 0;
SELECT 'abc' AND 1, '1abc' AND 1, '0' OR 0, ' 1' AND 1, '' OR 0;
SELECT '0.5' AND 1, '0.0' OR 0, '1e3' AND 1, '-2' AND 1;
SELECT x'00' OR 0, x'31' AND 1, x'' OR 0, x'01' OR 0;
SELECT NOT 'abc', NOT '1', NOT 0.1, NOT 2, NOT x'31';
-- Conditions in WHERE on values of many types.
CREATE TABLE v(id INTEGER, x);
INSERT INTO v VALUES
  (1, 0), (2, 1), (3, -7), (4, 0.0), (5, 0.25), (6, 'abc'), (7, '12abc'),
  (8, ''), (9, '0'), (10, NULL), (11, x'32'), (12, x'61'), (13, '  3'), (14, '0.001');
SELECT id FROM v WHERE x ORDER BY id;
SELECT id FROM v WHERE NOT x ORDER BY id;
SELECT id FROM v WHERE x IS NULL ORDER BY id;
-- WHERE with a constant condition.
SELECT id FROM v WHERE 1 ORDER BY id;
SELECT id FROM v WHERE 0 ORDER BY id;
SELECT id FROM v WHERE 'yes' ORDER BY id;
SELECT id FROM v WHERE '1' ORDER BY id;
