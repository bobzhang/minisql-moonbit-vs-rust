-- Affinity and collation for x IN (list): the left operand's affinity is
-- applied to the list values (a IN (x, y) behaves like a = +x OR a = +y),
-- and the left operand's collation is used.

CREATE TABLE t(id INTEGER, i INTEGER, r REAL, s TEXT, u, c TEXT COLLATE NOCASE);
INSERT INTO t VALUES (1, 1, 1.0, '1', '1', 'abc'), (2, 2, 2.5, '2.5', 2, 'ABC'), (3, 3, 3.0, 'x', x'33', 'xyz');
-- INTEGER column: text list values that look like numbers match.
SELECT id FROM t WHERE i IN ('1', '3') ORDER BY id;
SELECT id FROM t WHERE i IN ('1.0', 'x') ORDER BY id;
-- REAL column.
SELECT id FROM t WHERE r IN ('1', '2.5') ORDER BY id;
-- TEXT column: numeric list values are converted to text.
SELECT id FROM t WHERE s IN (1, 2.5) ORDER BY id;
-- Untyped column: no conversion.
SELECT id FROM t WHERE u IN (1, 2) ORDER BY id;
SELECT id FROM t WHERE u IN ('1', '2') ORDER BY id;
-- A literal on the left has no affinity: the columns in the list do not
-- lend it theirs.
SELECT id FROM t WHERE '1' IN (i) ORDER BY id;
SELECT id FROM t WHERE 1 IN (s) ORDER BY id;
SELECT id FROM t WHERE 1 IN (i) ORDER BY id;
-- Collation of the left operand.
SELECT id FROM t WHERE c IN ('ABC') ORDER BY id;
SELECT id FROM t WHERE c COLLATE BINARY IN ('ABC') ORDER BY id;
SELECT id FROM t WHERE 'ABC' IN (c) ORDER BY id;
SELECT id FROM t WHERE 'ABC' COLLATE NOCASE IN (c, 'none') ORDER BY id;
-- NOT IN with affinity.
SELECT id FROM t WHERE i NOT IN ('1', '2') ORDER BY id;
SELECT id FROM t WHERE s NOT IN (1) ORDER BY id;
