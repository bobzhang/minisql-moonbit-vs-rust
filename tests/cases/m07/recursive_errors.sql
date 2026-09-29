-- Invalid recursive CTEs, each next to valid variants of the same shape to
-- show what is allowed.
CREATE TABLE t(x INTEGER);
INSERT INTO t VALUES (1), (2), (3);

-- Valid baseline.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3) SELECT n FROM c ORDER BY n;

-- Error: aggregate in the recursive part.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT max(n) + 1 FROM c WHERE n < 3) SELECT n FROM c;
-- Error: GROUP BY in the recursive part is also an aggregate query.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 3 GROUP BY n) SELECT n FROM c;
-- Valid: aggregates are fine in the anchor ...
WITH RECURSIVE c(n) AS (SELECT max(x) FROM t UNION ALL SELECT n + 1 FROM c WHERE n < 5) SELECT n FROM c ORDER BY n;
-- ... and in the main query ...
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 5) SELECT count(*), sum(n), avg(n) FROM c;
-- ... and in a scalar subquery over another table inside the recursive part.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + (SELECT max(x) FROM t) FROM c WHERE n < 10) SELECT n FROM c ORDER BY n;

-- Error: the recursive table referenced twice in the recursive select.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT a.n + b.n FROM c a, c b WHERE a.n < 10) SELECT n FROM c;
-- Error: a second recursive reference inside a subquery.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n IN (SELECT n FROM c)) SELECT n FROM c;
-- Valid: the main query may reference the recursive CTE many times.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 4)
SELECT a.n, b.n FROM c a JOIN c b ON b.n = a.n * 2 ORDER BY a.n;
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 4)
SELECT n, (SELECT count(*) FROM c AS d WHERE d.n < c.n) FROM c ORDER BY n;
-- Valid: joining the recursive table with a real table several times.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT c.n + t1.x FROM c JOIN t t1 ON t1.x = 1 JOIN t t2 ON t2.x = 2 WHERE c.n < 4)
SELECT n FROM c ORDER BY n;

-- Error: a self-reference with no anchor (no compound) is circular.
WITH RECURSIVE c(n) AS (SELECT n + 1 FROM c) SELECT n FROM c;
-- Error: column count mismatch between anchor and recursive part.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n, n FROM c WHERE n < 3) SELECT n FROM c;
-- Valid: two columns in both parts.
WITH RECURSIVE c(n, m) AS (SELECT 1, 10 UNION ALL SELECT n + 1, m - 1 FROM c WHERE n < 3) SELECT n, m FROM c ORDER BY n;

-- Valid: DISTINCT is allowed in the recursive part.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT DISTINCT n + 1 FROM c, t WHERE n < 3) SELECT n FROM c ORDER BY n;
-- Valid: two CTEs, where the recursive one reads a non-recursive one.
WITH RECURSIVE step(s) AS (SELECT 2), c(n) AS (SELECT 0 UNION ALL SELECT n + s FROM c, step WHERE n < 6)
SELECT n FROM c ORDER BY n;
-- Valid: a non-recursive CTE after a recursive one reads it.
WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < 6), evens AS (SELECT n FROM c WHERE n % 2 = 0)
SELECT group_concat(n, ',' ORDER BY n) FROM evens;
-- Valid: the result of a recursive CTE in a scalar subquery.
SELECT (WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n * 3 FROM c WHERE n < 50) SELECT max(n) FROM c);
-- Valid: the recursive CTE inside an IN list of a plain SELECT.
SELECT x FROM t WHERE x IN (WITH RECURSIVE c(n) AS (SELECT 2 UNION ALL SELECT n + 2 FROM c WHERE n < 10) SELECT n FROM c) ORDER BY x;
-- Valid: the recursive part can use WHERE on a joined table's column only.
WITH RECURSIVE c(n) AS (SELECT 0 UNION ALL SELECT n + x FROM c JOIN t ON x = 3 WHERE n < 9) SELECT n FROM c ORDER BY n;
