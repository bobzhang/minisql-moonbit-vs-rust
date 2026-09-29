-- HAVING filters groups after aggregation.
CREATE TABLE t(dept TEXT, name TEXT, salary INTEGER);
INSERT INTO t VALUES
  ('eng', 'a', 100), ('eng', 'b', 120), ('eng', 'c', 90), ('ops', 'd', 70),
  ('ops', 'e', 80), ('hr', 'f', 60), ('sales', 'g', NULL), ('sales', 'h', 50);

SELECT dept, count(*) FROM t GROUP BY dept HAVING count(*) > 1 ORDER BY dept;
SELECT dept, sum(salary) FROM t GROUP BY dept HAVING sum(salary) >= 150 ORDER BY dept;
-- HAVING on an aggregate that is not selected.
SELECT dept FROM t GROUP BY dept HAVING max(salary) < 100 ORDER BY dept;
-- HAVING on the grouping column.
SELECT dept, avg(salary) FROM t GROUP BY dept HAVING dept <> 'eng' ORDER BY dept;
-- HAVING with AND/OR.
SELECT dept FROM t GROUP BY dept HAVING count(*) >= 2 AND min(salary) > 60 ORDER BY dept;
SELECT dept FROM t GROUP BY dept HAVING count(*) = 1 OR sum(salary) > 250 ORDER BY dept;
-- HAVING referencing an alias.
SELECT dept, sum(salary) AS total FROM t GROUP BY dept HAVING total > 100 ORDER BY total;
-- HAVING that is NULL for a group excludes it.
SELECT dept FROM t GROUP BY dept HAVING min(salary) > 55 ORDER BY dept;
SELECT dept, count(salary) FROM t GROUP BY dept HAVING count(salary) < count(*);

-- HAVING that removes every group.
SELECT dept FROM t GROUP BY dept HAVING count(*) > 100;
-- HAVING that keeps every group.
SELECT dept FROM t GROUP BY dept HAVING 1 ORDER BY dept;

-- HAVING without GROUP BY on an aggregate query.
SELECT count(*) FROM t HAVING count(*) > 5;
SELECT count(*) FROM t HAVING sum(salary) > 10000;

-- WHERE and HAVING together.
SELECT dept, count(*) FROM t WHERE salary > 75 GROUP BY dept HAVING count(*) >= 1 ORDER BY dept;

-- HAVING combined with LIMIT.
SELECT dept, sum(salary) FROM t GROUP BY dept HAVING sum(salary) IS NOT NULL ORDER BY 2 DESC LIMIT 2;

-- HAVING on a query that is not an aggregate is an error.
SELECT dept FROM t HAVING dept = 'eng';
