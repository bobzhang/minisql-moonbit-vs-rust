-- Correlated [NOT] EXISTS: semi-joins and anti-joins.
CREATE TABLE dept(did INTEGER PRIMARY KEY, dname TEXT);
CREATE TABLE emp(eid INTEGER PRIMARY KEY, did INTEGER, ename TEXT, salary INTEGER);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'art'), (4, 'law');
INSERT INTO emp VALUES (1, 1, 'ann', 100), (2, 1, 'bo', 90), (3, 2, 'cy', 50), (4, 3, 'di', NULL), (5, NULL, 'ed', 70);

-- Departments with at least one employee (each once, no duplicates).
SELECT dname FROM dept WHERE EXISTS (SELECT 1 FROM emp WHERE emp.did = dept.did) ORDER BY did;
-- Departments with no employees.
SELECT dname FROM dept WHERE NOT EXISTS (SELECT 1 FROM emp WHERE emp.did = dept.did) ORDER BY did;
-- Additional conditions inside the subquery.
SELECT dname FROM dept d WHERE EXISTS (SELECT 1 FROM emp e WHERE e.did = d.did AND e.salary > 80) ORDER BY did;
SELECT dname FROM dept d WHERE NOT EXISTS (SELECT 1 FROM emp e WHERE e.did = d.did AND e.salary IS NOT NULL) ORDER BY did;
-- Employees who are the top earner of their department (no one earns more).
SELECT ename FROM emp a WHERE salary IS NOT NULL AND NOT EXISTS
  (SELECT 1 FROM emp b WHERE b.did = a.did AND b.salary > a.salary) ORDER BY eid;
-- EXISTS in the select list, correlated.
SELECT dname, EXISTS (SELECT 1 FROM emp WHERE emp.did = dept.did) FROM dept ORDER BY did;
-- Correlated EXISTS with the outer row's column in a non-equality.
SELECT ename FROM emp a WHERE EXISTS (SELECT 1 FROM emp b WHERE b.salary < a.salary / 2) ORDER BY eid;
-- EXISTS vs IN on the same question.
SELECT count(*) FROM emp WHERE EXISTS (SELECT 1 FROM dept WHERE dept.did = emp.did);
SELECT count(*) FROM emp WHERE did IN (SELECT did FROM dept);
-- NOT EXISTS vs NOT IN differ when the key is NULL: ed has no department.
SELECT ename FROM emp WHERE NOT EXISTS (SELECT 1 FROM dept WHERE dept.did = emp.did) ORDER BY eid;
SELECT ename FROM emp WHERE did NOT IN (SELECT did FROM dept) ORDER BY eid;
-- EXISTS combined with OR and AND.
SELECT dname FROM dept WHERE did = 4 OR EXISTS (SELECT 1 FROM emp WHERE emp.did = dept.did AND ename LIKE 'c%') ORDER BY did;
-- Double negation: departments where every employee earns at least 90.
SELECT dname FROM dept d WHERE EXISTS (SELECT 1 FROM emp WHERE emp.did = d.did)
  AND NOT EXISTS (SELECT 1 FROM emp e WHERE e.did = d.did AND NOT (e.salary >= 90)) ORDER BY did;
-- After DML the correlated results change.
DELETE FROM emp WHERE did = 1;
SELECT dname FROM dept WHERE NOT EXISTS (SELECT 1 FROM emp WHERE emp.did = dept.did) ORDER BY did;
