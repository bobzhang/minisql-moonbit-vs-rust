-- FILTER (WHERE cond) restricts the rows an aggregate sees, independently
-- for each aggregate in the query.
CREATE TABLE s(id INTEGER, region TEXT, amount INTEGER, returned INTEGER);
INSERT INTO s VALUES
  (1, 'n', 100, 0), (2, 'n', 50, 1), (3, 's', 70, 0), (4, 's', 30, 0),
  (5, 'e', 20, 1), (6, 'n', NULL, 0), (7, 'e', 10, NULL);

SELECT count(*) FILTER (WHERE returned = 1), count(*) FILTER (WHERE returned = 0), count(*) FROM s;
SELECT sum(amount) FILTER (WHERE returned = 0), sum(amount) FILTER (WHERE returned = 1) FROM s;
SELECT region,
       count(*) FILTER (WHERE amount >= 50),
       sum(amount) FILTER (WHERE returned = 0),
       avg(amount) FILTER (WHERE amount IS NOT NULL)
FROM s GROUP BY region ORDER BY region;

-- A filter that matches nothing: count gives 0, sum NULL, total 0.0.
SELECT count(*) FILTER (WHERE 0), sum(amount) FILTER (WHERE 0), total(amount) FILTER (WHERE 0), max(amount) FILTER (WHERE 0) FROM s;
-- NULL filter results exclude the row.
SELECT count(*) FILTER (WHERE returned) FROM s;
SELECT count(*) FILTER (WHERE NOT returned) FROM s;

-- FILTER combined with WHERE: WHERE runs first.
SELECT count(*) FILTER (WHERE region = 'n') FROM s WHERE amount > 60;

-- FILTER with min/max and group_concat.
SELECT min(amount) FILTER (WHERE region <> 'n'), max(id) FILTER (WHERE returned = 0) FROM s;
SELECT group_concat(id, ',' ORDER BY id) FILTER (WHERE returned = 0) FROM s;

-- FILTER referring to columns not otherwise used.
SELECT sum(amount) FILTER (WHERE id % 2 = 1) FROM s;

-- FILTER with DISTINCT.
SELECT count(DISTINCT region) FILTER (WHERE amount < 60) FROM s;

-- FILTER in HAVING and ORDER BY.
SELECT region FROM s GROUP BY region HAVING count(*) FILTER (WHERE returned = 1) > 0 ORDER BY region;
SELECT region, sum(amount) FILTER (WHERE returned = 0) AS kept FROM s GROUP BY region ORDER BY kept DESC NULLS LAST, region;

-- FILTER on a non-aggregate function is an error.
SELECT abs(amount) FILTER (WHERE 1) FROM s;
-- FILTER may not contain an aggregate.
SELECT count(*) FILTER (WHERE sum(amount) > 1) FROM s;
