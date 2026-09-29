-- Result-column aliases ([AS] name) and table aliases (FROM t [AS] x).
-- Aliases do not change the printed output (no header line), but aliased
-- tables must be referenced by the alias.

CREATE TABLE emp(id INTEGER, name TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 100), (2, 'bob', 200), (3, 'cy', 150);
SELECT name AS n, salary AS s FROM emp ORDER BY id;
SELECT name n, salary s FROM emp ORDER BY id;
SELECT salary * 2 AS doubled, salary * 2 doubled2 FROM emp ORDER BY id;
-- Quoted aliases.
SELECT name AS "Employee Name", salary AS [pay] FROM emp ORDER BY id;
SELECT 1 AS 'one', 2 AS "two";
-- An alias may reuse a column name.
SELECT salary AS name, name AS salary FROM emp ORDER BY id;
-- Table alias with AS and without.
SELECT e.name FROM emp AS e ORDER BY e.id;
SELECT e.name, e.salary FROM emp e WHERE e.salary > 120 ORDER BY e.salary;
-- Unqualified names still work with a table alias.
SELECT name FROM emp AS e WHERE salary < 200 ORDER BY id;
-- The original table name cannot be used once it is aliased.
SELECT emp.name FROM emp AS e;
-- Alias in ORDER BY of the qualified column.
SELECT e.id, e.name FROM emp e ORDER BY e.salary DESC;
-- Aliases on literals without FROM.
SELECT 42 AS answer, 'x' AS letter, NULL AS empty_value;
-- Alias names that are keywords must be quoted.
SELECT 1 AS "from", 2 AS [select];
SELECT 1 AS from;
