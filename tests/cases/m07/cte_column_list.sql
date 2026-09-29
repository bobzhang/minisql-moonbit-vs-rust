-- WITH name(col, ...) AS (...): an explicit column list renames the CTE's
-- columns; its length must match the number of result columns.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'one'), (2, 'two'), (3, 'three');

-- The column list overrides the select's own names.
WITH c(x, y) AS (SELECT a, b FROM t) SELECT y, x FROM c ORDER BY x;

-- Columns without names in the body (expressions) get names from the list.
WITH c(n, sq, label) AS (SELECT a, a * a, 'v' || a FROM t) SELECT n, sq, label FROM c ORDER BY n;

-- The original column names are no longer visible.
WITH c(x) AS (SELECT a FROM t) SELECT a FROM c;

-- A column list on a VALUES body.
WITH v(k, name) AS (VALUES (1, 'x'), (2, 'y'), (3, NULL)) SELECT k, name FROM v ORDER BY k;

-- A column list on a compound body.
WITH u(val) AS (SELECT a FROM t UNION SELECT 10) SELECT val FROM u ORDER BY val;

-- Qualified references use the listed names.
WITH c(x, y) AS (SELECT a, b FROM t) SELECT c.x, c.y FROM c WHERE c.x = 2;

-- SELECT * expands to the listed names, usable by the outer query.
SELECT q.p FROM (WITH c(p, q) AS (SELECT a, b FROM t) SELECT * FROM c) AS q ORDER BY q.p;

-- Quoted column names in the list.
WITH c("my col", [other]) AS (SELECT a, b FROM t) SELECT "my col", other FROM c WHERE "my col" > 1 ORDER BY 1;

-- The list can make column names that shadow table column names in joins.
WITH c(a, extra) AS (SELECT a * 10, b FROM t) SELECT t.a, c.a FROM t JOIN c ON c.a = t.a * 10 ORDER BY t.a;

-- Column list with the same count as a SELECT *.
WITH c(p, q) AS (SELECT * FROM t) SELECT q FROM c WHERE p = 3;

-- Aggregate body with column list.
WITH stats(cnt, total, longest) AS (SELECT count(*), sum(a), max(length(b)) FROM t)
SELECT cnt, total, longest FROM stats;

-- Errors: too many / too few names in the list.
WITH c(x, y, z) AS (SELECT a, b FROM t) SELECT * FROM c;
WITH c(x) AS (SELECT a, b FROM t) SELECT * FROM c;
WITH c(x, y) AS (VALUES (1, 2, 3)) SELECT * FROM c;
