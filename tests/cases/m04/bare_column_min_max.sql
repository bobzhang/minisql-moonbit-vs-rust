-- SQLite's bare-column rule: in an aggregate query with a single min() or
-- max(), a non-aggregated column takes its value from the row that holds
-- the minimum or maximum. (Every extremum below is unique.)
CREATE TABLE emp(id INTEGER, name TEXT, dept TEXT, salary INTEGER, hired TEXT);
INSERT INTO emp VALUES
  (1, 'ann', 'eng', 120, '2019-03-01'), (2, 'bob', 'ops', 90, '2021-07-15'),
  (3, 'cat', 'eng', 150, '2018-01-10'), (4, 'dan', 'hr', 60, '2022-11-30'),
  (5, 'eve', 'ops', 95, '2020-05-05'), (6, 'fay', 'hr', NULL, '2023-02-01');

SELECT name, max(salary) FROM emp;
SELECT name, min(salary) FROM emp;
SELECT max(salary), name, dept, id FROM emp;
SELECT name, hired, min(hired) FROM emp;
SELECT name, max(hired) FROM emp;

-- The extremum of an expression.
SELECT name, max(length(name) * 100 + id) FROM emp;
SELECT name, min(salary - id * 10) FROM emp;

-- With WHERE: the rule applies to the filtered rows.
SELECT name, max(salary) FROM emp WHERE dept = 'ops';
SELECT name, min(salary) FROM emp WHERE salary > 60;

-- NULLs are ignored by min/max, so the NULL-salary row is never picked.
SELECT name, min(salary) FROM emp WHERE dept = 'hr';

-- Using the bare column in an expression.
SELECT upper(name) || ' earns ' || max(salary) FROM emp;

-- Text extremum.
SELECT id, max(name) FROM emp;
SELECT salary, min(name) FROM emp;

-- With aggregates that are not min/max alongside (count/sum do not affect
-- which row is chosen).
SELECT name, max(salary), count(*), sum(salary) FROM emp;
