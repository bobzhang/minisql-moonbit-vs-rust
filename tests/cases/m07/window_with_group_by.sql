-- Window functions in aggregate queries: windows are computed after
-- GROUP BY/HAVING, over the grouped rows, and may take aggregates as
-- arguments or in their ORDER BY.
CREATE TABLE sales(id INTEGER PRIMARY KEY, region TEXT, month INTEGER, amt INTEGER);
INSERT INTO sales VALUES
  (1, 'n', 1, 10), (2, 'n', 1, 5), (3, 'n', 2, 20), (4, 'n', 3, 7),
  (5, 's', 1, 30), (6, 's', 2, 1), (7, 's', 2, 2), (8, 'e', 3, 50), (9, 'e', 3, NULL);

-- Rank regions by total sales.
SELECT region, sum(amt), rank() OVER (ORDER BY sum(amt) DESC) FROM sales GROUP BY region ORDER BY region;

-- Running total of monthly totals.
SELECT month, sum(amt), sum(sum(amt)) OVER (ORDER BY month) FROM sales GROUP BY month ORDER BY month;

-- Share of each region in the grand total (window over the grouped rows).
SELECT region, sum(amt), sum(amt) * 100 / sum(sum(amt)) OVER () FROM sales GROUP BY region ORDER BY region;

-- Month-over-month change per region.
SELECT region, month, sum(amt), sum(amt) - lag(sum(amt)) OVER (PARTITION BY region ORDER BY month)
FROM sales GROUP BY region, month ORDER BY region, month;

-- Number of groups via count(*) OVER () in a grouped query.
SELECT region, count(*), count(*) OVER () FROM sales GROUP BY region ORDER BY region;

-- HAVING is applied before the window function.
SELECT region, sum(amt), row_number() OVER (ORDER BY region) FROM sales GROUP BY region HAVING sum(amt) > 30 ORDER BY region;

-- Window partitioned by a grouping column, ordered by an aggregate.
SELECT region, month, count(*), dense_rank() OVER (PARTITION BY region ORDER BY count(*) DESC, month)
FROM sales GROUP BY region, month ORDER BY region, month;

-- Aggregate without GROUP BY plus a window: one row.
SELECT sum(amt), count(*) OVER () FROM sales;

-- A window over grouped rows with a frame.
SELECT month, sum(amt), avg(sum(amt)) OVER (ORDER BY month ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM sales GROUP BY month ORDER BY month;

-- max(count(*)) OVER: which group sizes are the largest.
SELECT region, count(*) = max(count(*)) OVER () FROM sales GROUP BY region ORDER BY region;

-- Grouping by an expression, windowing over it.
SELECT amt / 10 AS bucket, count(*), sum(count(*)) OVER (ORDER BY amt / 10) FROM sales WHERE amt IS NOT NULL GROUP BY amt / 10 ORDER BY bucket;

-- DISTINCT inside the aggregate argument of a grouped query, then windowed.
SELECT region, count(DISTINCT month), rank() OVER (ORDER BY count(DISTINCT month) DESC) FROM sales GROUP BY region ORDER BY region;

-- Errors: window function in GROUP BY, in HAVING, and in WHERE.
SELECT region FROM sales GROUP BY rank() OVER (ORDER BY id);
SELECT region FROM sales GROUP BY region HAVING rank() OVER (ORDER BY region) = 1;
SELECT id FROM sales WHERE row_number() OVER (ORDER BY id) = 1;
