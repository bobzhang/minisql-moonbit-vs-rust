-- JOIN ... USING (cols): equality on same-named columns of both tables.
CREATE TABLE emp(name TEXT, dept TEXT, site TEXT);
CREATE TABLE budget(dept TEXT, site TEXT, amount INTEGER);
INSERT INTO emp VALUES ('ann', 'eng', 'nyc'), ('bob', 'eng', 'sf'), ('cy', 'ops', 'nyc'), ('dot', NULL, 'nyc');
INSERT INTO budget VALUES ('eng', 'nyc', 100), ('eng', 'sf', 80), ('ops', 'sf', 30), (NULL, 'nyc', 1);

-- Single column.
SELECT name, dept, amount FROM emp JOIN budget USING (dept) ORDER BY name, amount;
-- Two columns: both must be equal.
SELECT name, dept, site, amount FROM emp JOIN budget USING (dept, site) ORDER BY name;
-- Column order inside USING does not matter.
SELECT name, amount FROM emp JOIN budget USING (site, dept) ORDER BY name;
-- The USING column may be referenced unqualified, or qualified with either table.
SELECT name, dept, emp.dept, budget.dept FROM emp JOIN budget USING (dept, site) ORDER BY name;
-- Other shared columns not in USING stay ambiguous when unqualified...
SELECT site FROM emp JOIN budget USING (dept);
-- ...but can be qualified.
SELECT name, emp.site, budget.site FROM emp JOIN budget USING (dept) ORDER BY name, budget.site;
-- NULL values in USING columns never match.
SELECT count(*) FROM emp JOIN budget USING (dept);
-- LEFT JOIN USING.
SELECT name, dept, amount FROM emp LEFT JOIN budget USING (dept, site) ORDER BY name;
-- USING in WHERE and ORDER BY.
SELECT name FROM emp JOIN budget USING (dept, site) WHERE dept = 'eng' ORDER BY site DESC;
SELECT dept, sum(amount) FROM emp JOIN budget USING (dept) GROUP BY dept ORDER BY dept;
-- USING with aliases.
SELECT e.name, b.amount FROM emp AS e JOIN budget AS b USING (dept, site) ORDER BY e.name;
-- Errors: USING a column that is missing from one side, or from both.
SELECT * FROM emp JOIN budget USING (name);
SELECT * FROM emp JOIN budget USING (nosuch);
