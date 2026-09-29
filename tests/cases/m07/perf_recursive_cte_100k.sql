-- @timeout 5
-- Performance: recursive CTEs producing 100k rows, aggregated directly,
-- carried in several columns, and materialized into a table with
-- WITH ... INSERT. A linear-time recursion is required; nothing here needs
-- more than O(n log n) work.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
SELECT count(*), sum(x), min(x), max(x) FROM c;

-- Several columns per row; Fibonacci modulo a prime.
WITH RECURSIVE f(n, a, b) AS (SELECT 1, 0, 1 UNION ALL SELECT n + 1, b, (a + b) % 1000000007 FROM f WHERE n < 100000)
SELECT n, b FROM f WHERE n = 100000;

-- Filtering and grouping the generated rows.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
SELECT x % 7, count(*), sum(x) FROM c WHERE x % 3 = 0 GROUP BY x % 7 ORDER BY 1;

-- Materialize 100k rows into a table.
CREATE TABLE t(id INTEGER PRIMARY KEY, g INTEGER, v INTEGER);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 100000)
INSERT INTO t SELECT x, x % 100, (x * 7919) % 10007 FROM c;
SELECT count(*), sum(v), min(v), max(v) FROM t;
SELECT g, count(*), sum(v) FROM t WHERE g IN (0, 1, 99) GROUP BY g ORDER BY g;

-- A second CTE reading the first, joined back to the table by primary key.
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1000 FROM c WHERE x < 99000),
  picked AS (SELECT t.id, t.v FROM c JOIN t ON t.id = c.x)
SELECT count(*), sum(v) FROM picked;

-- Recursive string building limited by LIMIT inside the CTE.
WITH RECURSIVE s(n, str) AS (SELECT 1, 'x' UNION ALL SELECT n + 1, substr(str || char(97 + n % 26), -20) FROM s LIMIT 50000)
SELECT count(*), max(n), length(max(str)) FROM s;

-- UNION ALL recursion with a bounded depth over a 100k-row table: each
-- level follows a primary-key lookup.
WITH RECURSIVE hop(id, depth) AS (SELECT 1, 0 UNION ALL
  SELECT t.id, hop.depth + 1 FROM hop JOIN t ON t.id = (hop.id * 3) % 100000 + 1 WHERE hop.depth < 50000)
SELECT count(*), max(depth), sum(id) FROM hop;
