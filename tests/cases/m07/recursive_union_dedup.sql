-- Recursive CTEs with UNION (not UNION ALL): rows already produced are
-- discarded, so recursion over a cycle terminates.
-- A cycle 1 -> 2 -> 3 -> 1: UNION terminates once no new value appears.
WITH RECURSIVE c(x) AS (SELECT 1 UNION SELECT x % 3 + 1 FROM c)
SELECT x FROM c ORDER BY x;

-- Values that repeat: n -> n / 2 reaches 0 and then stays at 0.
WITH RECURSIVE c(x) AS (SELECT 100 UNION SELECT x / 2 FROM c)
SELECT x FROM c ORDER BY x;

-- UNION ALL of the same recursion would not terminate; with a LIMIT on the
-- recursive CTE we can see the repeated values it produces
-- (7 rows: 1,2,3,1,2,3,1).
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x % 3 + 1 FROM c LIMIT 7)
SELECT x, count(*) FROM c GROUP BY x ORDER BY x;

-- UNION also removes duplicates within the anchor.
WITH RECURSIVE c(x) AS (VALUES (1), (1), (2) UNION SELECT x + 10 FROM c WHERE x < 10)
SELECT x FROM c ORDER BY x;

-- Duplicates are judged on the whole row, not a single column.
WITH RECURSIVE c(a, b) AS (SELECT 0, 0 UNION SELECT (a + 1) % 3, b FROM c)
SELECT a, b FROM c ORDER BY a, b;

-- Collatz sequence from 27 visits each value once; count and max.
WITH RECURSIVE z(n) AS (SELECT 27 UNION SELECT CASE WHEN n % 2 = 0 THEN n / 2 ELSE 3 * n + 1 END FROM z)
SELECT count(*), max(n) FROM z;

-- Graph reachability with cycles via UNION.
CREATE TABLE edge(src INTEGER, dst INTEGER);
INSERT INTO edge VALUES (1, 2), (2, 3), (3, 1), (3, 4), (5, 6), (6, 5), (4, 4);
WITH RECURSIVE reach(n) AS (SELECT 1 UNION SELECT dst FROM edge JOIN reach ON src = n)
SELECT n FROM reach ORDER BY n;
WITH RECURSIVE reach(n) AS (SELECT 5 UNION SELECT dst FROM edge JOIN reach ON src = n)
SELECT n FROM reach ORDER BY n;
-- A node with a self-loop only reaches itself.
WITH RECURSIVE reach(n) AS (SELECT 4 UNION SELECT dst FROM edge JOIN reach ON src = n)
SELECT n FROM reach ORDER BY n;

-- UNION dedup compares values: 1 and 1.0 are equal, so 1.0 is not added again.
WITH RECURSIVE c(x) AS (SELECT 1 UNION SELECT 1.0 FROM c) SELECT x, typeof(x) FROM c;

-- NULLs are considered duplicates of each other by UNION.
WITH RECURSIVE c(x, k) AS (SELECT NULL, 0 UNION SELECT NULL, 0 FROM c) SELECT count(*) FROM c;

-- Text values with the dedup; 'a' || '' equals 'a'.
WITH RECURSIVE c(s) AS (SELECT 'a' UNION SELECT s || '' FROM c UNION SELECT 'b' FROM c)
SELECT s FROM c ORDER BY s;

-- Counting the reachable set sizes from every start node.
WITH RECURSIVE r(start, n) AS (SELECT src, src FROM edge UNION SELECT r.start, e.dst FROM r JOIN edge e ON e.src = r.n)
SELECT start, count(*) FROM r GROUP BY start ORDER BY start;
