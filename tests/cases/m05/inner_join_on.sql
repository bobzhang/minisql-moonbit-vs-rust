-- [INNER] JOIN ... ON: only row pairs where the ON condition is true.
CREATE TABLE dept(id INTEGER PRIMARY KEY, dname TEXT);
CREATE TABLE emp(id INTEGER PRIMARY KEY, ename TEXT, dept_id INTEGER, salary INTEGER);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'sales');
INSERT INTO emp VALUES
  (10, 'ann', 1, 120), (11, 'bob', 1, 100), (12, 'cid', 2, 90),
  (13, 'dee', NULL, 80), (14, 'eve', 4, 70);

-- Basic equi-join; employees without a matching department disappear.
SELECT ename, dname FROM emp JOIN dept ON emp.dept_id = dept.id ORDER BY ename;
SELECT ename, dname FROM emp INNER JOIN dept ON dept.id = emp.dept_id ORDER BY ename;
-- The departments with no employees also disappear.
SELECT DISTINCT dname FROM dept JOIN emp ON emp.dept_id = dept.id ORDER BY dname;
-- ON may contain arbitrary expressions, not just equality.
SELECT ename, dname FROM emp JOIN dept ON emp.dept_id = dept.id AND salary >= 100 ORDER BY ename;
SELECT ename, dname FROM emp JOIN dept ON emp.dept_id < dept.id ORDER BY ename, dname;
SELECT count(*) FROM emp JOIN dept ON 1;
SELECT count(*) FROM emp JOIN dept ON 0;
SELECT count(*) FROM emp JOIN dept ON NULL;
-- For inner joins, a condition in ON or in WHERE gives the same result.
SELECT ename FROM emp JOIN dept ON emp.dept_id = dept.id WHERE dname = 'eng' ORDER BY ename;
SELECT ename FROM emp JOIN dept ON emp.dept_id = dept.id AND dname = 'eng' ORDER BY ename;
-- Aliases and qualified *.
SELECT e.ename, d.* FROM emp AS e JOIN dept AS d ON e.dept_id = d.id ORDER BY e.id;
SELECT d.dname, e.* FROM emp e JOIN dept d ON e.dept_id = d.id ORDER BY e.id;
-- Star over a join: left table's columns then right table's.
SELECT * FROM dept JOIN emp ON emp.dept_id = dept.id ORDER BY emp.id;
-- Joins feed ORDER BY on columns of either side.
SELECT ename, dname FROM emp JOIN dept ON emp.dept_id = dept.id ORDER BY dname DESC, salary;
-- Joining on an expression of the columns.
SELECT e.ename, d.dname FROM emp e JOIN dept d ON e.dept_id + 1 = d.id ORDER BY e.ename;
-- Errors: ON referencing a table that is not part of the join, unknown column.
SELECT ename FROM emp JOIN dept ON emp.dept_id = other.id;
SELECT ename FROM emp JOIN dept ON emp.nosuch = dept.id;
