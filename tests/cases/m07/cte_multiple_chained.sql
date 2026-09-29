-- Several CTEs in one WITH clause; later CTEs may reference earlier ones.
CREATE TABLE sales(id INTEGER PRIMARY KEY, region TEXT, amount INTEGER);
INSERT INTO sales VALUES
  (1, 'north', 100), (2, 'north', 250), (3, 'south', 50), (4, 'south', 75),
  (5, 'east', 300), (6, 'east', 20), (7, 'west', NULL);

-- Two independent CTEs combined in the main query.
WITH a AS (SELECT 1 AS x), b AS (SELECT 2 AS y) SELECT x, y FROM a, b;

-- A chain: totals depends on filtered, ranked depends on totals.
WITH filtered AS (SELECT region, amount FROM sales WHERE amount IS NOT NULL),
     totals AS (SELECT region, sum(amount) AS total FROM filtered GROUP BY region),
     big AS (SELECT region, total FROM totals WHERE total > 100)
SELECT region, total FROM big ORDER BY total DESC;

-- Main query joins several CTEs of the chain.
WITH totals AS (SELECT region, sum(amount) AS total FROM sales GROUP BY region),
     grand AS (SELECT sum(total) AS g FROM totals)
SELECT region, total, round(total * 100.0 / g, 2) FROM totals, grand WHERE total IS NOT NULL ORDER BY region;

-- A CTE referencing an earlier CTE twice.
WITH n AS (VALUES (1), (2), (3)), pairs AS (SELECT a.column1 AS p, b.column1 AS q FROM n a, n b WHERE a.column1 < b.column1)
SELECT p, q FROM pairs ORDER BY p, q;

-- Three levels deep with column lists.
WITH l1(v) AS (SELECT amount FROM sales WHERE region = 'north'),
     l2(v2) AS (SELECT v + 1 FROM l1),
     l3(v3) AS (SELECT v2 * 2 FROM l2)
SELECT v3 FROM l3 ORDER BY v3;

-- A later CTE can be defined in terms of a compound of earlier ones.
WITH lo AS (SELECT id FROM sales WHERE amount < 60),
     hi AS (SELECT id FROM sales WHERE amount > 200),
     ends AS (SELECT id FROM lo UNION ALL SELECT id FROM hi)
SELECT id FROM ends ORDER BY id;

-- Main query uses only the last CTE; earlier ones are used indirectly.
WITH a AS (SELECT region FROM sales WHERE id <= 4), b AS (SELECT DISTINCT region FROM a)
SELECT count(*) FROM b;

-- A CTE may refer to an earlier one even inside a subquery expression.
WITH mx AS (SELECT max(amount) AS m FROM sales),
     top AS (SELECT id, region FROM sales WHERE amount = (SELECT m FROM mx))
SELECT id, region FROM top;

-- The main query can use an earlier CTE and a derived one side by side.
WITH a AS (SELECT 41 AS x), b AS (SELECT x + 1 AS y FROM a) SELECT x, y FROM a, b;

-- Error: duplicate CTE name in one WITH clause.
WITH a AS (SELECT 1), a AS (SELECT 2) SELECT * FROM a;
-- Error: reference to a CTE name that does not exist.
WITH a AS (SELECT 1 AS x) SELECT * FROM b;
