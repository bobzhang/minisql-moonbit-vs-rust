-- Derived tables as join operands: inner, left and right joins, USING and
-- NATURAL with derived column names, and self-joins of derived tables.
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 100), (2, 'bo', 'eng', 80), (3, 'cy', 'ops', 60), (4, 'di', 'ops', 65), (5, 'ed', 'hr', 50);

-- Employees above their department average.
SELECT e.name FROM emp e JOIN (SELECT dept, avg(salary) AS a FROM emp GROUP BY dept) d ON d.dept = e.dept
  WHERE e.salary > d.a ORDER BY e.name;
-- USING on a derived column.
SELECT name, mx FROM emp JOIN (SELECT dept, max(salary) AS mx FROM emp GROUP BY dept) USING (dept) ORDER BY id;
-- NATURAL JOIN picks up the shared column name of the derived table.
SELECT name, headcount FROM emp NATURAL JOIN (SELECT dept, count(*) AS headcount FROM emp GROUP BY dept) ORDER BY id;
-- LEFT JOIN a derived table that lacks some keys.
SELECT d.dept, x.n FROM (SELECT DISTINCT dept FROM emp) d
  LEFT JOIN (SELECT dept, count(*) AS n FROM emp WHERE salary >= 65 GROUP BY dept) x ON x.dept = d.dept ORDER BY d.dept;
-- RIGHT JOIN with a derived table on the left.
SELECT hi.name, e.name FROM (SELECT * FROM emp WHERE salary > 70) hi RIGHT JOIN emp e ON hi.id = e.id ORDER BY e.id;
-- Joining two derived tables built from the same table.
SELECT a.name, b.name FROM (SELECT * FROM emp WHERE dept = 'eng') a JOIN (SELECT * FROM emp WHERE dept = 'ops') b
  ON a.salary > b.salary + 20 ORDER BY a.name, b.name;
-- A derived table built from a join.
SELECT n, total FROM (SELECT e1.name AS n, e1.salary + e2.salary AS total FROM emp e1 JOIN emp e2 ON e1.dept = e2.dept AND e1.id < e2.id) ORDER BY total DESC;
-- Derived table of VALUES as a lookup table.
SELECT name, label FROM emp JOIN (SELECT 'eng' AS dept, 'Engineering' AS label UNION ALL SELECT 'ops', 'Operations') USING (dept) ORDER BY id;
-- Three sources: table, derived aggregate, derived filter.
SELECT e.name, d.a, f.name FROM emp e JOIN (SELECT dept, avg(salary) AS a FROM emp GROUP BY dept) d USING (dept)
  LEFT JOIN (SELECT name, dept FROM emp WHERE salary < 60) f ON f.dept = e.dept ORDER BY e.id;
-- * over a join with a derived table.
SELECT * FROM (SELECT dept, count(*) AS c FROM emp GROUP BY dept) x JOIN (SELECT 'ops' AS dept, 1 AS flag) y USING (dept);
