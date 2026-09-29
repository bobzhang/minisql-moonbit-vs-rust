-- @db file
-- Views stored in sqlite_schema (type 'view', rootpage 0): the engine must
-- parse their CREATE VIEW text, including column lists, joins, aggregates,
-- compound selects, CTEs and views built on other views.
-- @phase sqlite
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary INTEGER);
CREATE TABLE dept(id INTEGER PRIMARY KEY, title TEXT);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'empty');
INSERT INTO emp VALUES (1, 'ann', 1, 100), (2, 'ben', 1, 120), (3, 'cid', 2, 90), (4, 'dee', NULL, 50), (5, 'eve', 2, 95);
CREATE VIEW v_rich AS SELECT name, salary FROM emp WHERE salary >= 100;
CREATE VIEW v_dept_totals(dept_title, headcount, payroll) AS
  SELECT d.title, count(e.id), sum(e.salary) FROM dept d LEFT JOIN emp e ON e.dept = d.id GROUP BY d.id;
CREATE VIEW v_names AS SELECT name FROM emp UNION ALL SELECT title FROM dept;
CREATE VIEW "v nested" AS SELECT dept_title, payroll * 2 AS double_pay FROM v_dept_totals WHERE headcount > 0;
CREATE VIEW v_ranked AS
  WITH ranked AS (SELECT name, salary, rank() OVER (ORDER BY salary DESC) AS r FROM emp)
  SELECT name, r FROM ranked;
-- @phase engine
SELECT type, name, tbl_name FROM sqlite_schema WHERE type = 'view' ORDER BY name;
SELECT * FROM v_rich ORDER BY name;
SELECT * FROM v_dept_totals ORDER BY dept_title;
SELECT count(*) FROM v_names;
SELECT name FROM v_names ORDER BY name DESC LIMIT 3;
SELECT * FROM "v nested" ORDER BY dept_title;
SELECT name, r FROM v_ranked ORDER BY r, name;
SELECT e.name, t.payroll FROM emp e JOIN v_dept_totals t ON t.dept_title = 'eng' WHERE e.dept = 1 ORDER BY e.name;
SELECT headcount FROM v_dept_totals WHERE dept_title = 'empty';
-- Views are read-only.
INSERT INTO v_rich VALUES ('zed', 1);
SELECT * FROM v_missing;
