-- Views containing GROUP BY, HAVING, DISTINCT, ORDER BY and LIMIT; querying
-- them filters and aggregates the view's result rows.
CREATE TABLE sales(region TEXT, rep TEXT, amount INTEGER);
INSERT INTO sales VALUES ('n', 'a', 10), ('n', 'b', 20), ('s', 'c', 5), ('s', 'c', 15), ('e', 'd', 40), ('w', 'e', NULL);

CREATE VIEW region_totals AS SELECT region, sum(amount) AS total, count(*) AS n FROM sales GROUP BY region;
SELECT * FROM region_totals ORDER BY region;
-- WHERE on a view column acts like HAVING on the underlying query.
SELECT region FROM region_totals WHERE total >= 20 ORDER BY region;
SELECT region FROM region_totals WHERE total IS NULL;
-- Aggregating a view of aggregates.
SELECT sum(total), max(n), avg(total) FROM region_totals;
-- A view with HAVING.
CREATE VIEW busy AS SELECT rep, count(*) AS c FROM sales GROUP BY rep HAVING count(*) > 1;
SELECT * FROM busy;
-- DISTINCT view.
CREATE VIEW reps AS SELECT DISTINCT rep FROM sales;
SELECT count(*) FROM reps;
-- ORDER BY and LIMIT inside the view define which rows it contains.
CREATE VIEW top2 AS SELECT region, total FROM region_totals WHERE total IS NOT NULL ORDER BY total DESC LIMIT 2;
SELECT region, total FROM top2 ORDER BY region;
SELECT count(*) FROM top2;
-- Aggregate view without GROUP BY always has exactly one row.
CREATE VIEW stats AS SELECT count(*) AS cnt, min(amount) AS lo, max(amount) AS hi FROM sales;
SELECT * FROM stats;
DELETE FROM sales;
SELECT * FROM stats;
SELECT count(*) FROM region_totals;
-- Re-populated data flows through immediately.
INSERT INTO sales VALUES ('x', 'z', 7), ('x', 'y', 3);
SELECT * FROM region_totals;
SELECT * FROM stats;
-- Joining an aggregate view back to its base table.
SELECT s.rep, s.amount * 100 / r.total AS pct FROM sales s JOIN region_totals r USING (region) ORDER BY s.rep;
