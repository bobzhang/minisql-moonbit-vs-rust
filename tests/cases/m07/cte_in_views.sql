-- CTEs inside view definitions and views used inside CTEs (M6 views + M7).
CREATE TABLE emp(id INTEGER PRIMARY KEY, name TEXT, mgr INTEGER, pay INTEGER);
INSERT INTO emp VALUES (1, 'amy', NULL, 300), (2, 'ben', 1, 200), (3, 'cat', 1, 210),
  (4, 'dan', 2, 100), (5, 'eli', 2, 120), (6, 'fox', 5, 90);

-- A view whose body is a WITH query.
CREATE VIEW big_earners AS WITH avgpay AS (SELECT avg(pay) AS a FROM emp)
  SELECT name, pay FROM emp, avgpay WHERE pay > a;
SELECT name, pay FROM big_earners ORDER BY pay DESC;

-- A view defined with a recursive CTE (the reporting chain under amy).
CREATE VIEW chain(name, depth) AS WITH RECURSIVE r(id, name, depth) AS (
  SELECT id, name, 0 FROM emp WHERE mgr IS NULL
  UNION ALL SELECT e.id, e.name, r.depth + 1 FROM emp e JOIN r ON e.mgr = r.id)
  SELECT name, depth FROM r;
SELECT name, depth FROM chain ORDER BY depth, name;
SELECT max(depth), count(*) FROM chain;

-- The view reflects later changes to the base table.
INSERT INTO emp VALUES (7, 'gus', 6, 50);
SELECT name, depth FROM chain WHERE depth >= 3 ORDER BY name;

-- A CTE reading a view.
WITH deep AS (SELECT name FROM chain WHERE depth >= 2) SELECT group_concat(name, ',' ORDER BY name) FROM deep;

-- A CTE and a view with the same name: the CTE wins in its statement.
WITH chain(name, depth) AS (SELECT 'cte', -1) SELECT name, depth FROM chain;

-- A view joined with a CTE.
WITH lvl(depth, label) AS (VALUES (0, 'top'), (1, 'mid'), (2, 'low'))
SELECT c.name, coalesce(l.label, 'deep') FROM chain c LEFT JOIN lvl l ON l.depth = c.depth ORDER BY c.depth, c.name;

-- A view using a CTE with a column list, queried with a filter.
CREATE VIEW squares AS WITH RECURSIVE s(n, sq) AS (SELECT 1, 1 UNION ALL SELECT n + 1, (n + 1) * (n + 1) FROM s WHERE n < 20)
  SELECT n, sq FROM s;
SELECT n, sq FROM squares WHERE sq BETWEEN 50 AND 200 ORDER BY n;
SELECT count(*), sum(sq) FROM squares;

-- A view over a view built from CTEs.
CREATE VIEW odd_squares AS SELECT n, sq FROM squares WHERE n % 2 = 1;
SELECT group_concat(sq, ' ' ORDER BY n) FROM odd_squares WHERE n < 10;

-- Dropping the base view breaks the dependent view at query time.
DROP VIEW squares;
SELECT count(*) FROM odd_squares;
DROP VIEW odd_squares;

-- Error: views are read-only even when defined by a CTE.
DELETE FROM chain;
SELECT count(*) FROM chain;
