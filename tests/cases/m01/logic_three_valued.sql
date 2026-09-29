-- AND / OR / NOT with SQL three-valued logic (1, 0, NULL).

-- AND truth table.
SELECT 1 AND 1, 1 AND 0, 0 AND 1, 0 AND 0;
SELECT 1 AND NULL, NULL AND 1, 0 AND NULL, NULL AND 0, NULL AND NULL;
-- OR truth table.
SELECT 1 OR 1, 1 OR 0, 0 OR 1, 0 OR 0;
SELECT 1 OR NULL, NULL OR 1, 0 OR NULL, NULL OR 0, NULL OR NULL;
-- NOT.
SELECT NOT 1, NOT 0, NOT NULL;
SELECT NOT NOT 1, NOT NOT 0, NOT NOT NULL;
-- Results are integers 0/1.
SELECT typeof(1 AND 1), typeof(NOT 0), typeof(NULL AND 1), 5 AND 7, 5 OR 0;
-- Combined with comparisons.
SELECT 1 < 2 AND 2 < 3, 1 < 2 AND 3 < 2, 1 > 2 OR 2 > 1, NOT 1 = 1;
SELECT NULL = 1 OR 1 = 1, NULL = 1 AND 1 = 1, NULL = 1 AND 1 = 2;
-- AND binds tighter than OR.
SELECT 1 OR 0 AND 0, (1 OR 0) AND 0, 0 AND 0 OR 1, 0 AND (0 OR 1);
-- NOT binds looser than comparisons but tighter than AND.
SELECT NOT 1 = 2, NOT 0 AND 0, NOT (0 AND 0), NOT 0 OR 1;
-- Three-valued logic in WHERE: only rows where the condition is true pass.
CREATE TABLE t(id INTEGER, a INTEGER, b INTEGER);
INSERT INTO t VALUES (1, 1, 1), (2, 1, 0), (3, 1, NULL), (4, 0, NULL), (5, NULL, NULL), (6, 0, 0);
SELECT id, a AND b, a OR b, NOT a FROM t ORDER BY id;
SELECT id FROM t WHERE a AND b ORDER BY id;
SELECT id FROM t WHERE a OR b ORDER BY id;
SELECT id FROM t WHERE NOT (a AND b) ORDER BY id;
SELECT id FROM t WHERE NOT (a OR b) ORDER BY id;
