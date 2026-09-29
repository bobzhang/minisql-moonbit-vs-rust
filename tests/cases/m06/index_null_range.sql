-- NULL handling and range boundaries with indexes: NULLs never satisfy =, <,
-- >, BETWEEN or IN; IS NULL / IS NOT NULL / IS find them; boundaries are
-- inclusive or exclusive as written.
CREATE TABLE t(id INTEGER PRIMARY KEY, k INTEGER, j INTEGER);
INSERT INTO t VALUES (1, NULL, 1), (2, 1, NULL), (3, 2, 2), (4, 2, NULL), (5, 3, 3), (6, NULL, NULL), (7, 5, 5), (8, -1, 1);
CREATE INDEX t_k ON t(k);
CREATE INDEX t_kj ON t(k, j);

SELECT id FROM t WHERE k IS NULL ORDER BY id;
SELECT id FROM t WHERE k IS NOT NULL ORDER BY id;
SELECT id FROM t WHERE k = NULL;
SELECT id FROM t WHERE k IS 2 ORDER BY id;
SELECT id FROM t WHERE k < 2 ORDER BY id;
SELECT id FROM t WHERE k <= 2 ORDER BY id;
SELECT id FROM t WHERE k > 2 ORDER BY id;
SELECT id FROM t WHERE k >= 2 ORDER BY id;
SELECT id FROM t WHERE k > 1 AND k < 5 ORDER BY id;
SELECT id FROM t WHERE k BETWEEN 1 AND 3 ORDER BY id;
SELECT id FROM t WHERE k NOT BETWEEN 1 AND 3 ORDER BY id;
SELECT id FROM t WHERE k IN (2, NULL, 5) ORDER BY id;
SELECT id FROM t WHERE k NOT IN (2, 5) ORDER BY id;
SELECT id FROM t WHERE k <> 2 ORDER BY id;
-- Empty ranges.
SELECT id FROM t WHERE k > 3 AND k < 4;
SELECT id FROM t WHERE k > 5;
SELECT id FROM t WHERE k < -1;
SELECT id FROM t WHERE k BETWEEN 3 AND 1;
-- Multi-column index: equality on the first column, conditions on the second.
SELECT id FROM t WHERE k = 2 AND j IS NULL;
SELECT id FROM t WHERE k = 2 AND j >= 2;
SELECT id FROM t WHERE k IS NULL AND j IS NULL;
SELECT id FROM t WHERE k IS NULL AND j = 1;
-- ORDER BY an indexed column containing NULLs.
SELECT id FROM t ORDER BY k, id;
SELECT id FROM t ORDER BY k DESC, id;
-- Real and integer bounds.
SELECT id FROM t WHERE k > 1.5 AND k < 2.5 ORDER BY id;
SELECT id FROM t WHERE k >= 2.0 ORDER BY id;
-- Aggregates on indexed columns with NULLs.
SELECT count(k), min(k), max(k), count(*) FROM t;
SELECT count(*) FROM t WHERE k > -100;
