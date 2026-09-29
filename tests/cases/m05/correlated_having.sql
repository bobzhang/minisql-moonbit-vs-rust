-- Correlated subqueries in HAVING and grouped queries: the subquery can refer
-- to the group's columns and aggregates of the outer query.
CREATE TABLE sales(region TEXT, rep TEXT, amount INTEGER);
CREATE TABLE targets(region TEXT, goal INTEGER);
INSERT INTO sales VALUES
  ('east', 'a', 10), ('east', 'b', 30), ('west', 'c', 5), ('west', 'd', 5),
  ('north', 'e', 50), ('south', 'f', 1);
INSERT INTO targets VALUES ('east', 35), ('west', 20), ('north', 40), ('south', 1);

-- Regions that met their target.
SELECT region, sum(amount) FROM sales GROUP BY region
  HAVING sum(amount) >= (SELECT goal FROM targets t WHERE t.region = sales.region) ORDER BY region;
-- Regions that missed it, with the shortfall computed by a correlated subquery in the select list.
SELECT region, (SELECT goal FROM targets t WHERE t.region = sales.region) - sum(amount) FROM sales GROUP BY region
  HAVING sum(amount) < (SELECT goal FROM targets t WHERE t.region = sales.region) ORDER BY region;
-- HAVING with a correlated EXISTS.
SELECT region FROM sales GROUP BY region HAVING EXISTS (SELECT 1 FROM targets t WHERE t.region = sales.region AND t.goal > 30) ORDER BY region;
-- HAVING with a correlated count over the same table.
SELECT region, count(*) FROM sales s GROUP BY region
  HAVING (SELECT count(*) FROM sales s2 WHERE s2.amount > 20 AND s2.region = s.region) > 0 ORDER BY region;
-- An aggregate of an outer column inside a subquery belongs to the OUTER query:
-- sum(s.amount) below is the group's sum, not a sum over targets rows.
SELECT region, (SELECT sum(s.amount) FROM targets) FROM sales s GROUP BY region ORDER BY region;
-- Using the outer aggregate in the subquery's WHERE.
SELECT region, (SELECT count(*) FROM targets t WHERE t.goal <= sum(s.amount)) FROM sales s GROUP BY region ORDER BY region;
-- Subquery in the GROUP BY key.
SELECT (SELECT goal FROM targets t WHERE t.region = s.region) >= 30 AS big, count(*), sum(amount) FROM sales s GROUP BY big ORDER BY big;
-- Aggregate over a correlated subquery value.
SELECT sum((SELECT goal FROM targets t WHERE t.region = s.region)) FROM sales s;
SELECT max((SELECT goal FROM targets t WHERE t.region = s.region) - amount) FROM sales s;
-- Grouped query in FROM, filtered by a correlated subquery.
SELECT g.region, g.total FROM (SELECT region, sum(amount) AS total FROM sales GROUP BY region) g
  WHERE g.total > (SELECT goal FROM targets t WHERE t.region = g.region) ORDER BY g.region;
