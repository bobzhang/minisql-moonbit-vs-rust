-- @db file
-- M7 features against a file: recursive and non-recursive CTEs joined with
-- file tables, window functions with partitions, frames and named windows.
-- @phase sqlite
PRAGMA page_size = 4096;
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, boss INTEGER, dept TEXT, salary INTEGER);
CREATE INDEX emp_boss ON emp(boss);
INSERT INTO emp VALUES (1, 'root', NULL, 'exec', 500);
WITH RECURSIVE c(i) AS (SELECT 2 UNION ALL SELECT i + 1 FROM c WHERE i < 2000)
INSERT INTO emp SELECT i, 'e' || i, i / 3, CASE i % 3 WHEN 0 THEN 'eng' WHEN 1 THEN 'ops' ELSE 'sales' END, 100 + (i * 37) % 300 FROM c;
-- @phase engine
-- Chain of command up from employee 1999.
WITH RECURSIVE up(id, name, boss, depth) AS (
  SELECT id, name, boss, 0 FROM emp WHERE id = 1999
  UNION ALL SELECT e.id, e.name, e.boss, up.depth + 1 FROM emp e JOIN up ON e.id = up.boss)
SELECT depth, id, name FROM up ORDER BY depth;
-- Size of the subtree under employee 5.
WITH RECURSIVE down(id) AS (SELECT 5 UNION ALL SELECT e.id FROM emp e JOIN down ON e.boss = down.id)
SELECT count(*), sum(salary) FROM emp WHERE id IN (SELECT id FROM down);
WITH stats AS (SELECT dept, avg(salary) AS a, count(*) AS n FROM emp GROUP BY dept)
SELECT dept, n, a FROM stats ORDER BY dept;
SELECT id, dept, salary, rank() OVER (PARTITION BY dept ORDER BY salary DESC) AS r
FROM emp WHERE id BETWEEN 100 AND 120 ORDER BY dept, r, id;
SELECT id, salary, sum(salary) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW),
       lag(salary) OVER w, lead(salary, 2, -1) OVER w
FROM emp WHERE id <= 8 WINDOW w AS (ORDER BY id) ORDER BY id;
SELECT dept, id, salary FROM (
  SELECT dept, id, salary, row_number() OVER (PARTITION BY dept ORDER BY salary DESC, id) AS rn FROM emp)
WHERE rn <= 2 ORDER BY dept, rn;
SELECT ntile(4) OVER (ORDER BY id) AS q, count(*) OVER (PARTITION BY dept) FROM emp WHERE id IN (2, 3, 4, 5, 6, 7, 8, 9) ORDER BY id;
SELECT id, first_value(name) OVER (PARTITION BY boss ORDER BY id), count(*) OVER (PARTITION BY boss) FROM emp WHERE boss = 40 ORDER BY id;
SELECT salary, count(*) OVER (ORDER BY salary RANGE BETWEEN 5 PRECEDING AND 5 FOLLOWING) FROM emp WHERE id <= 12 ORDER BY salary, id;
