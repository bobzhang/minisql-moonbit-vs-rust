-- Filtering on window results through subqueries and CTEs: top-N per group,
-- deduplication, and selecting rows around a condition.
CREATE TABLE emp(id INTEGER PRIMARY KEY, dept TEXT, name TEXT, salary INTEGER, hired TEXT);
INSERT INTO emp VALUES
  (1, 'eng', 'ann', 150, '2019-03-01'), (2, 'eng', 'bob', 120, '2020-01-15'), (3, 'eng', 'cy', 150, '2018-07-01'),
  (4, 'eng', 'dee', 90, '2021-05-20'), (5, 'ops', 'ed', 80, '2017-02-02'), (6, 'ops', 'flo', 95, '2019-09-09'),
  (7, 'hr', 'gil', 70, '2022-11-11'), (8, 'ops', 'hal', 95, '2016-06-06');

-- Top 2 salaries per dept with row_number (ties broken by id).
SELECT dept, name, salary FROM (
  SELECT dept, name, salary, row_number() OVER (PARTITION BY dept ORDER BY salary DESC, id) AS rn FROM emp)
WHERE rn <= 2 ORDER BY dept, salary DESC, name;

-- With rank(): ties can yield more than N rows.
SELECT dept, name FROM (SELECT dept, name, rank() OVER (PARTITION BY dept ORDER BY salary DESC) AS rk FROM emp)
WHERE rk = 1 ORDER BY dept, name;

-- Same using a CTE.
WITH ranked AS (SELECT *, dense_rank() OVER (PARTITION BY dept ORDER BY salary DESC) AS dr FROM emp)
SELECT dept, name, salary, dr FROM ranked WHERE dr <= 2 ORDER BY dept, dr, name;

-- Most recent hire per dept.
WITH h AS (SELECT dept, name, row_number() OVER (PARTITION BY dept ORDER BY hired DESC) AS rn FROM emp)
SELECT dept, name FROM h WHERE rn = 1 ORDER BY dept;

-- Deduplicate: keep the lowest id per (dept, salary).
SELECT id, dept, salary FROM (SELECT id, dept, salary, row_number() OVER (PARTITION BY dept, salary ORDER BY id) AS rn FROM emp)
WHERE rn = 1 ORDER BY id;

-- Rows whose salary is above their dept average.
SELECT name FROM (SELECT name, salary, avg(salary) OVER (PARTITION BY dept) AS da FROM emp) WHERE salary > da ORDER BY name;

-- Employees earning more than the previous hire in the same dept.
SELECT name FROM (SELECT name, salary, lag(salary) OVER (PARTITION BY dept ORDER BY hired) AS prev FROM emp)
WHERE salary > prev ORDER BY name;

-- The second page (rows 3-4) of a ranking.
SELECT name, salary FROM (SELECT name, salary, row_number() OVER (ORDER BY salary DESC, id) AS rn FROM emp)
WHERE rn BETWEEN 3 AND 4 ORDER BY rn;

-- Window results joined back to the base table.
SELECT e.name, r.pos FROM emp e JOIN (SELECT id, row_number() OVER (ORDER BY hired) AS pos FROM emp) r ON r.id = e.id
WHERE r.pos <= 3 ORDER BY r.pos;

-- Window over the result of a join.
CREATE TABLE dept(name TEXT PRIMARY KEY, floor INTEGER);
INSERT INTO dept VALUES ('eng', 3), ('ops', 1), ('hr', 2);
SELECT e.name, d.floor, rank() OVER (ORDER BY d.floor, e.salary DESC) FROM emp e JOIN dept d ON d.name = e.dept ORDER BY e.id;

-- IN with a window-derived subquery.
SELECT name FROM emp WHERE id IN (SELECT id FROM (SELECT id, ntile(4) OVER (ORDER BY salary, id) AS q FROM emp) WHERE q = 4) ORDER BY name;

-- EXISTS with a window inside the subquery.
SELECT DISTINCT dept FROM emp e WHERE EXISTS (SELECT 1 FROM (SELECT dept, count(*) OVER (PARTITION BY dept) AS c FROM emp) x WHERE x.dept = e.dept AND x.c >= 3) ORDER BY dept;
