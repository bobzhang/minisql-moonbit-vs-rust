-- ORDER BY and LIMIT/OFFSET inside a recursive CTE.
-- * ORDER BY on the recursive part decides which queued row is processed
--   next (e.g. depth-first vs breadth-first).
-- * LIMIT on the recursive part caps the total number of rows the CTE ever
--   produces (anchor rows included); OFFSET skips output rows, but skipped
--   rows are still used to generate further rows.
-- The effect of the queue order is made visible through LIMIT: different
-- orders select different sets of rows.
CREATE TABLE org(id INTEGER PRIMARY KEY, name TEXT, boss INTEGER);
INSERT INTO org VALUES (1, 'ceo', NULL), (2, 'cto', 1), (3, 'cfo', 1), (4, 'dev1', 2),
  (5, 'dev2', 2), (6, 'acct', 3), (7, 'intern', 4);

-- Depth-first (deepest queued row first, ties by name DESC), first 4 rows.
WITH RECURSIVE t(id, name, depth) AS (
  SELECT id, name, 0 FROM org WHERE boss IS NULL
  UNION ALL
  SELECT org.id, org.name, t.depth + 1 FROM org JOIN t ON org.boss = t.id
  ORDER BY 3 DESC, 2 DESC LIMIT 4)
SELECT name, depth FROM t ORDER BY name;

-- Breadth-first (shallowest first, ties by name DESC), first 4 rows.
WITH RECURSIVE t(id, name, depth) AS (
  SELECT id, name, 0 FROM org WHERE boss IS NULL
  UNION ALL
  SELECT org.id, org.name, t.depth + 1 FROM org JOIN t ON org.boss = t.id
  ORDER BY 3, 2 DESC LIMIT 4)
SELECT name, depth FROM t ORDER BY name;

-- Without LIMIT, both orders produce the whole tree.
WITH RECURSIVE t(id, name, depth) AS (
  SELECT id, name, 0 FROM org WHERE boss IS NULL
  UNION ALL
  SELECT org.id, org.name, t.depth + 1 FROM org JOIN t ON org.boss = t.id
  ORDER BY 3 DESC, 2)
SELECT name, depth FROM t ORDER BY depth, name;

-- ORDER BY by name of a result column works when the anchor names it.
WITH RECURSIVE c(x) AS (SELECT 1 AS x UNION ALL SELECT x + 1 FROM c WHERE x < 5 ORDER BY x)
SELECT x FROM c ORDER BY x;

-- LIMIT in the recursive part: at most 5 rows in total, anchor included.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 5)
SELECT x FROM c ORDER BY x;
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 5)
SELECT count(*), sum(x) FROM c;

-- LIMIT with several anchor rows: the anchors count toward the limit.
WITH RECURSIVE c(x) AS (VALUES (10), (20), (30) UNION ALL SELECT x + 1 FROM c ORDER BY 1 LIMIT 5)
SELECT x FROM c ORDER BY x;

-- OFFSET skips the first output rows, but they still feed the recursion.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10 LIMIT 3 OFFSET 2)
SELECT x FROM c ORDER BY x;

-- LIMIT larger than the natural result: no effect.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 4 LIMIT 100)
SELECT x FROM c ORDER BY x;

-- LIMIT 0: the CTE is empty (not even the anchor).
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 4 LIMIT 0)
SELECT count(*) FROM c;

-- Negative LIMIT means no limit.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 4 LIMIT -1)
SELECT count(*) FROM c;

-- Priority-queue order with UNION and LIMIT: the smallest values first.
-- Each value n produces 2n and 3n; ORDER BY 1 extracts the smallest queued
-- value next, so the first 10 rows are the 10 smallest 3-smooth numbers
-- of the form 2^a * 3^b.
WITH RECURSIVE h(n) AS (SELECT 1 UNION SELECT n * 2 FROM h UNION SELECT n * 3 FROM h ORDER BY 1 LIMIT 10)
SELECT group_concat(n, ',' ORDER BY n) FROM h;

-- Same generator with UNION ALL and a single recursive arm.
WITH RECURSIVE h(n) AS (SELECT 1 UNION ALL SELECT n * 2 FROM h ORDER BY 1 DESC LIMIT 6)
SELECT group_concat(n, ',' ORDER BY n) FROM h;

-- Queue order with two independent chains: ORDER BY value interleaves them,
-- so LIMIT 6 takes the 6 smallest across both chains.
WITH RECURSIVE c(chain, v) AS (SELECT 'a', 1 UNION ALL SELECT 'b', 100
  UNION ALL SELECT chain, v + 50 FROM c ORDER BY 2 LIMIT 6)
SELECT chain, v FROM c ORDER BY chain, v;

-- Same with ORDER BY value DESC: always extends the largest chain.
WITH RECURSIVE c(chain, v) AS (SELECT 'a', 1 UNION ALL SELECT 'b', 100
  UNION ALL SELECT chain, v + 50 FROM c ORDER BY 2 DESC LIMIT 6)
SELECT chain, v FROM c ORDER BY chain, v;
