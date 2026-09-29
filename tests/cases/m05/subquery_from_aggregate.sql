-- Aggregating over derived tables and joining derived aggregates.
CREATE TABLE sales(day INTEGER, shop TEXT, amount INTEGER);
INSERT INTO sales VALUES
  (1, 'n', 10), (1, 's', 20), (2, 'n', 15), (2, 's', 5), (3, 'n', 40), (3, 'e', 7), (4, 's', 30);

-- Aggregate of an aggregate: average daily total.
SELECT avg(total) FROM (SELECT day, sum(amount) AS total FROM sales GROUP BY day);
-- Max per-shop total and which shop.
SELECT shop, total FROM (SELECT shop, sum(amount) AS total FROM sales GROUP BY shop) ORDER BY total DESC, shop LIMIT 1;
-- Count groups meeting a condition.
SELECT count(*) FROM (SELECT shop FROM sales GROUP BY shop HAVING count(*) >= 2);
-- Filtering on an aggregate in the outer query instead of HAVING.
SELECT shop, n FROM (SELECT shop, count(*) AS n FROM sales GROUP BY shop) WHERE n > 1 ORDER BY shop;
-- Join a table with an aggregate of itself: each sale's share of its day's total.
SELECT s.day, s.shop, s.amount * 100 / d.total AS pct FROM sales s
  JOIN (SELECT day, sum(amount) AS total FROM sales GROUP BY day) d ON d.day = s.day ORDER BY s.day, s.shop;
-- Two derived aggregates joined together.
SELECT a.shop, a.total, b.best FROM (SELECT shop, sum(amount) AS total FROM sales GROUP BY shop) a
  JOIN (SELECT shop, max(amount) AS best FROM sales GROUP BY shop) b ON a.shop = b.shop ORDER BY a.shop;
-- Aggregate over a derived table with no rows.
SELECT count(*), sum(x), max(x) FROM (SELECT amount AS x FROM sales WHERE day > 10);
-- Grouping the output of a derived table.
SELECT bucket, count(*) FROM (SELECT CASE WHEN amount >= 20 THEN 'big' ELSE 'small' END AS bucket FROM sales) GROUP BY bucket ORDER BY bucket;
-- A derived table with a single aggregate row cross-joined to every row.
SELECT day, shop, amount - avg_amt > 0 FROM sales, (SELECT avg(amount) AS avg_amt FROM sales) ORDER BY day, shop;
-- Days whose total exceeds the overall average daily total.
SELECT day FROM (SELECT day, sum(amount) AS t FROM sales GROUP BY day)
  WHERE t > (SELECT avg(t2) FROM (SELECT sum(amount) AS t2 FROM sales GROUP BY day)) ORDER BY day;
-- group_concat over an ordered derived table.
SELECT group_concat(shop, '') FROM (SELECT DISTINCT shop FROM sales ORDER BY shop);
