-- RIGHT [OUTER] JOIN keeps every row of the right table; right rows without
-- a match get NULLs for all left-hand columns.
CREATE TABLE emp(ename TEXT, dept_id INTEGER);
CREATE TABLE dept(id INTEGER, dname TEXT);
INSERT INTO emp VALUES ('ann', 1), ('bob', 1), ('cid', 2), ('dee', NULL), ('eve', 7);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'hr'), (NULL, 'limbo');

SELECT ename, dname FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id ORDER BY dname, ename;
SELECT ename, dname FROM emp RIGHT OUTER JOIN dept ON emp.dept_id = dept.id ORDER BY dname, ename;
-- * lists the left table's columns first even though the right side is preserved.
SELECT * FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id ORDER BY dname, ename;
-- A RIGHT JOIN is a LEFT JOIN with the operands swapped.
SELECT ename, dname FROM dept LEFT JOIN emp ON emp.dept_id = dept.id ORDER BY dname, ename;
-- Counting per preserved row.
SELECT dname, count(ename) FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id GROUP BY dname ORDER BY dname;
-- Unmatched right rows only.
SELECT dname FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id WHERE emp.dept_id IS NULL ORDER BY dname;
-- The left-hand NULL-extended values are real NULLs.
SELECT dname, typeof(ename), typeof(emp.dept_id) FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id
  WHERE ename IS NULL ORDER BY dname;
-- Empty left table: every right row NULL-extended.
CREATE TABLE none_t(dept_id INTEGER, v TEXT);
SELECT v, dname FROM none_t RIGHT JOIN dept ON none_t.dept_id = dept.id ORDER BY dname;
-- Empty right table: no rows.
SELECT * FROM dept RIGHT JOIN none_t ON none_t.dept_id = dept.id;
-- ON condition that never holds.
SELECT ename, dname FROM emp RIGHT JOIN dept ON 0 ORDER BY dname;
-- RIGHT JOIN with a comma join on its left.
SELECT e1.ename, e2.ename, dname FROM emp e1, emp e2 RIGHT JOIN dept
  ON e1.dept_id = dept.id AND e2.dept_id = dept.id AND e1.ename < e2.ename ORDER BY dname, 1, 2;
-- RIGHT JOIN followed by an inner join.
CREATE TABLE loc(dname TEXT, city TEXT);
INSERT INTO loc VALUES ('eng', 'paris'), ('hr', 'rome'), ('limbo', 'nowhere');
SELECT ename, dept.dname, city FROM emp RIGHT JOIN dept ON emp.dept_id = dept.id
  JOIN loc ON loc.dname = dept.dname ORDER BY city, ename;
