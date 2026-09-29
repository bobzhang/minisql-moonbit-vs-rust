-- @db file
-- Views created by the engine are stored as schema rows with type 'view'
-- and rootpage 0; their CREATE VIEW text must be something SQLite can
-- parse and run: column lists, joins, aggregates, compound selects, CTEs,
-- window functions, and views built on views.
-- @phase engine
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, dept INTEGER, salary INTEGER);
CREATE TABLE dept(id INTEGER PRIMARY KEY, title TEXT);
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops'), (3, 'empty');
INSERT INTO emp VALUES (1, 'ann', 1, 100), (2, 'ben', 1, 120), (3, 'cid', 2, 90), (4, 'dee', NULL, 50), (5, 'eve', 2, 95);
CREATE VIEW v_rich AS SELECT name, salary FROM emp WHERE salary >= 100;
CREATE VIEW v_dept_totals(dept_title, headcount, payroll) AS
  SELECT d.title, count(e.id), sum(e.salary) FROM dept d LEFT JOIN emp e ON e.dept = d.id GROUP BY d.id;
CREATE VIEW v_names AS SELECT name FROM emp UNION SELECT title FROM dept;
CREATE VIEW "v nested" AS SELECT dept_title, payroll * 2 AS double_pay FROM v_dept_totals WHERE headcount > 0;
CREATE VIEW v_ranked AS
  WITH ranked AS (SELECT name, salary, rank() OVER (ORDER BY salary DESC) AS r FROM emp)
  SELECT name, r FROM ranked;
CREATE VIEW IF NOT EXISTS v_rich AS SELECT 1;
CREATE VIEW v_rich AS SELECT 1;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema WHERE type = 'view' ORDER BY name;
SELECT * FROM v_rich ORDER BY name;
SELECT * FROM v_dept_totals ORDER BY dept_title;
SELECT count(*) FROM v_names;
SELECT * FROM "v nested" ORDER BY dept_title;
SELECT name, r FROM v_ranked ORDER BY r, name;
INSERT INTO emp VALUES (6, 'fay', 3, 200);
CREATE VIEW v_by_sqlite AS SELECT title FROM dept WHERE id > 1;
-- @phase engine
SELECT * FROM v_dept_totals ORDER BY dept_title;
SELECT * FROM v_by_sqlite ORDER BY title;
DROP VIEW v_names;
-- @phase sqlite
SELECT type, name FROM sqlite_schema WHERE type = 'view' ORDER BY name;
