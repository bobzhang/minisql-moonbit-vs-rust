-- Non-recursive common table expressions in front of a SELECT: a CTE acts
-- like a named subquery that can be referenced (several times) in FROM.
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES
  (1, 'ann', 'eng', 120), (2, 'bob', 'eng', 100), (3, 'cid', 'ops', 80),
  (4, 'dee', 'ops', 95), (5, 'eve', 'hr', 70), (6, 'fay', NULL, 60);

-- Simplest form: a CTE over a table, filtered in the main query.
WITH rich AS (SELECT * FROM emp WHERE salary >= 95)
SELECT name, salary FROM rich ORDER BY salary DESC;

-- A CTE without FROM (constant rows).
WITH one AS (SELECT 1 AS a, 'x' AS b) SELECT a, b, typeof(a) FROM one;

-- Column names of the CTE come from the select's aliases / column names.
WITH s AS (SELECT dept AS d, salary * 2 AS double_pay FROM emp)
SELECT d, double_pay FROM s WHERE double_pay > 150 ORDER BY double_pay;

-- The CTE is referenced twice (self-join of a CTE).
WITH s AS (SELECT id, dept, salary FROM emp WHERE dept IS NOT NULL)
SELECT a.id, b.id FROM s a JOIN s b ON a.dept = b.dept AND a.id < b.id ORDER BY a.id, b.id;

-- A CTE containing aggregation, joined back to the base table.
WITH avg_by_dept AS (SELECT dept, avg(salary) AS av FROM emp GROUP BY dept)
SELECT e.name, e.salary, a.av FROM emp e JOIN avg_by_dept a ON e.dept = a.dept
WHERE e.salary > a.av ORDER BY e.name;

-- Aggregating over a CTE.
WITH s AS (SELECT salary FROM emp WHERE dept = 'eng') SELECT count(*), sum(salary), max(salary) FROM s;

-- A CTE that returns no rows.
WITH none AS (SELECT * FROM emp WHERE salary > 1000) SELECT count(*) FROM none;
WITH none AS (SELECT * FROM emp WHERE salary > 1000) SELECT * FROM none;

-- The CTE may be unused by the main query.
WITH unused AS (SELECT 1) SELECT count(*) FROM emp;

-- Table alias on a CTE reference, and qualified column references.
WITH s AS (SELECT id, name FROM emp) SELECT x.id, x.name FROM s AS x WHERE x.id IN (2, 4) ORDER BY x.id;

-- DISTINCT, ORDER BY and LIMIT inside the CTE body.
WITH top2 AS (SELECT name, salary FROM emp ORDER BY salary DESC LIMIT 2)
SELECT name FROM top2 ORDER BY name;
WITH depts AS (SELECT DISTINCT dept FROM emp) SELECT count(*), count(dept) FROM depts;

-- NULL values pass through a CTE unchanged.
WITH s AS (SELECT name, dept FROM emp WHERE dept IS NULL) SELECT name, dept, typeof(dept) FROM s;

-- SELECT * from a CTE with expressions.
WITH s AS (SELECT id, salary + 1 AS s1, upper(name) AS un FROM emp WHERE id <= 2)
SELECT * FROM s ORDER BY id;

-- Keywords are case-insensitive.
with Q as (select 7 as v) SELECT v FROM q;

-- Error: a CTE is only visible in its own statement.
SELECT * FROM rich;
-- Error: the CTE has no column named salary.
WITH s AS (SELECT name FROM emp) SELECT salary FROM s;
