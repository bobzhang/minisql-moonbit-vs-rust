-- IN / NOT IN with NULLs: if no element matches and the list contains a
-- NULL (or the left side is NULL), the result is NULL, not false.

SELECT 1 IN (1, NULL), 2 IN (1, NULL), 2 NOT IN (1, NULL), 1 NOT IN (1, NULL);
SELECT NULL IN (1, 2), NULL NOT IN (1, 2), NULL IN (NULL), NULL NOT IN (NULL);
SELECT typeof(2 IN (1, NULL)), typeof(1 IN (1, NULL));
-- An empty list is false even for NULL on the left.
SELECT NULL IN (), NULL NOT IN ();
-- The classic trap: NOT IN with a NULL in the list filters every row.
CREATE TABLE t(id INTEGER, v INTEGER);
INSERT INTO t VALUES (1, 1), (2, 2), (3, 3), (4, NULL);
SELECT id FROM t WHERE v NOT IN (1, NULL) ORDER BY id;
SELECT id FROM t WHERE v NOT IN (1) ORDER BY id;
SELECT id FROM t WHERE v IN (1, NULL) ORDER BY id;
SELECT id FROM t WHERE NOT (v IN (2, NULL)) ORDER BY id;
SELECT id, v IN (1, 2), v IN (1, NULL), v NOT IN (1, NULL) FROM t ORDER BY id;
-- IS NULL on the IN result distinguishes NULL from false.
SELECT id FROM t WHERE (v IN (1, NULL)) IS NULL ORDER BY id;
-- An expression that evaluates to NULL in the list.
SELECT 3 IN (1, 1 / 0), 1 IN (1, 1 / 0), 3 NOT IN (1, 1 / 0);
