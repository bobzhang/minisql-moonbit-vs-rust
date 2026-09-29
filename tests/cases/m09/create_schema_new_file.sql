-- @db file
-- The engine creates a new database file (it does not exist before the
-- first phase) holding tables, indexes, UNIQUE/PRIMARY KEY autoindexes and
-- views. SQLite must be able to open it, parse every schema entry, pass
-- integrity_check, query everything, and modify it; the engine then reads
-- SQLite's changes.
-- @phase engine
CREATE TABLE dept(id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE emp(
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  dept_id INTEGER REFERENCES dept(id),
  salary REAL DEFAULT 1000.0 CHECK (salary >= 0),
  email TEXT COLLATE NOCASE,
  UNIQUE (email)
);
CREATE INDEX emp_dept ON emp(dept_id);
CREATE INDEX emp_name_salary ON emp(name, salary DESC);
CREATE VIEW emp_view AS SELECT e.name, d.name AS dept FROM emp e LEFT JOIN dept d ON d.id = e.dept_id;
INSERT INTO dept VALUES (1, 'eng'), (2, 'ops');
INSERT INTO emp(id, name, dept_id, salary, email) VALUES (1, 'ann', 1, 1500.5, 'Ann@x.org'), (2, 'bob', 2, 900, 'bob@x.org');
INSERT INTO emp(id, name, dept_id, email) VALUES (3, 'cy', NULL, NULL);
SELECT * FROM emp_view ORDER BY name;
-- @phase sqlite
PRAGMA integrity_check;
SELECT type, name, tbl_name FROM sqlite_schema ORDER BY name;
SELECT * FROM emp ORDER BY id;
SELECT * FROM emp_view ORDER BY name;
SELECT name FROM emp INDEXED BY emp_dept WHERE dept_id = 2;
SELECT name FROM emp WHERE email = 'ANN@X.ORG';
-- Constraints still work in SQLite on the engine's file.
INSERT INTO emp(id, name, email) VALUES (4, 'dup', 'ann@x.org');
INSERT INTO dept VALUES (3, 'eng');
INSERT INTO emp(id, name, salary) VALUES (5, 'neg', -1);
INSERT INTO emp(id, name, dept_id, email) VALUES (6, 'dee', 2, 'dee@x.org');
PRAGMA integrity_check;
-- @phase engine
SELECT * FROM emp ORDER BY id;
SELECT dept, count(*) FROM emp_view GROUP BY dept ORDER BY dept;
