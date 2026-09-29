-- Comparison affinity: when a column with TEXT affinity is compared with a
-- numeric value that has no affinity (a literal), the number is converted
-- to TEXT and compared as text.

CREATE TABLE t(id INTEGER, s TEXT);
INSERT INTO t VALUES (1, '10'), (2, '9'), (3, '100'), (4, '1e1'), (5, 'abc'), (6, '10.0'), (7, ' 10');
SELECT id FROM t WHERE s = 10 ORDER BY id;
SELECT id FROM t WHERE s = 10.0 ORDER BY id;
SELECT id FROM t WHERE s = '10' ORDER BY id;
-- Ordering is textual: '9' > '10' and '100' < '9'.
SELECT id FROM t WHERE s > 9 ORDER BY id;
SELECT id FROM t WHERE s < 9 ORDER BY id;
SELECT id FROM t WHERE s < 2 ORDER BY id;
-- The literal on the left.
SELECT id FROM t WHERE 10 = s ORDER BY id;
SELECT id FROM t WHERE 5 < s ORDER BY id;
-- A real literal becomes its text form.
CREATE TABLE u(id INTEGER, s TEXT);
INSERT INTO u VALUES (1, '2.5'), (2, '2.50'), (3, '0.5'), (4, '.5');
SELECT id FROM u WHERE s = 2.5 ORDER BY id;
SELECT id FROM u WHERE s = 0.5 ORDER BY id;
SELECT id FROM u WHERE s = 2.50 ORDER BY id;
-- In the select list.
SELECT id, s = 10, s > 9, s < 100 FROM t ORDER BY id;
-- A number stored in a TEXT column was converted on insert, so it matches
-- the text form.
INSERT INTO t VALUES (8, 42);
SELECT id, typeof(s) FROM t WHERE s = 42;
SELECT id FROM t WHERE s = '42';
-- BLOB literals are never converted.
SELECT id FROM t WHERE s = x'3130' ORDER BY id;
