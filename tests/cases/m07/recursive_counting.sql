-- Basic recursive CTEs: an initial (anchor) select, UNION ALL, and a
-- recursive select that reads the CTE's previous rows.
-- Generate 1..10.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 10)
SELECT x FROM c ORDER BY x;

-- Aggregates over a generated series.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100)
SELECT count(*), sum(x), min(x), max(x), avg(x) FROM c;

-- Counting down and stepping.
WITH RECURSIVE c(x) AS (SELECT 10 UNION ALL SELECT x - 3 FROM c WHERE x > 0)
SELECT x FROM c ORDER BY x DESC;

-- Doubling: the termination test is on the previous row.
WITH RECURSIVE p(n) AS (SELECT 1 UNION ALL SELECT n * 2 FROM p WHERE n < 1000)
SELECT group_concat(n, ',' ORDER BY n) FROM p;

-- An anchor producing several rows: each row is recursed independently.
WITH RECURSIVE c(start, x) AS (SELECT 1, 1 UNION ALL SELECT 100, 100 UNION ALL
  SELECT start, x + 1 FROM c WHERE x < start + 2)
SELECT start, x FROM c ORDER BY start, x;

-- The anchor may be a VALUES list.
WITH RECURSIVE c(x) AS (VALUES (5), (7) UNION ALL SELECT x + 10 FROM c WHERE x < 20)
SELECT x FROM c ORDER BY x;

-- A recursion whose anchor returns nothing produces nothing.
WITH RECURSIVE c(x) AS (SELECT 1 WHERE 0 UNION ALL SELECT x + 1 FROM c WHERE x < 5)
SELECT count(*) FROM c;

-- The recursive step that never matches: only the anchor row.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 0)
SELECT x FROM c;

-- A LIMIT on the recursive select bounds an otherwise endless recursion.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 5)
SELECT x FROM c ORDER BY x;

-- Outer WHERE on an (otherwise bounded) recursion.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 30)
SELECT x FROM c WHERE x % 7 = 0 ORDER BY x;

-- A recursive CTE without an explicit column list uses the anchor's names.
WITH RECURSIVE c AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM c WHERE n < 4)
SELECT n FROM c ORDER BY n;

-- REAL arithmetic in the recursion.
WITH RECURSIVE h(x) AS (SELECT 1.0 UNION ALL SELECT x / 2 FROM h WHERE x > 0.1)
SELECT x FROM h ORDER BY x DESC;

-- Text accumulation.
WITH RECURSIVE s(n, str) AS (SELECT 1, 'a' UNION ALL SELECT n + 1, str || char(97 + n) FROM s WHERE n < 6)
SELECT n, str FROM s ORDER BY n;

-- SQLite also treats a self-referencing CTE as recursive when the RECURSIVE
-- keyword is omitted.
WITH c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 3) SELECT x FROM c ORDER BY x;

-- Using the series in a join with a table (a "numbers table").
CREATE TABLE words(w TEXT);
INSERT INTO words VALUES ('cat'), ('horse');
WITH RECURSIVE i(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM i WHERE n < 5)
SELECT w, n, substr(w, n, 1) FROM words JOIN i ON n <= length(w) ORDER BY w, n;
