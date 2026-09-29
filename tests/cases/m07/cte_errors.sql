-- Error handling for WITH clauses, interleaved with valid statements that
-- show the nearest correct form.
CREATE TABLE t(a INTEGER, b TEXT);
INSERT INTO t VALUES (1, 'x'), (2, 'y');

-- Valid baseline.
WITH c AS (SELECT a FROM t) SELECT a FROM c ORDER BY a;
-- Error: missing parentheses around the CTE body.
WITH c AS SELECT a FROM t SELECT a FROM c;
-- Error: WITH clause without a following statement.
WITH c AS (SELECT a FROM t);
-- Valid: quoted CTE names.
WITH "my cte" AS (SELECT 1 AS v) SELECT v FROM "my cte";
WITH [br cte] AS (SELECT 2 AS v) SELECT v FROM [br cte];

-- Valid: a one-name column list.
WITH c(z) AS (SELECT a FROM t) SELECT z FROM c ORDER BY z;
-- Error: empty column list.
WITH c() AS (SELECT a FROM t) SELECT * FROM c;

-- Valid: a CTE joined to a table with USING, and referenced in a subquery.
WITH c(a) AS (SELECT 2) SELECT t.a, t.b FROM t JOIN c USING (a);
WITH c AS (SELECT a FROM t) SELECT a FROM c WHERE a > (SELECT min(a) FROM c) ORDER BY a;
WITH c AS (SELECT a FROM t) SELECT count(*) FROM c, c AS d;

-- Valid: duplicate names across different WITH clauses are fine.
WITH c AS (SELECT 1 AS v) SELECT v, (WITH c AS (SELECT 2 AS v) SELECT v FROM c) FROM c;

-- Valid: CTE names are case-insensitive, so this reference resolves.
WITH MyCte AS (SELECT 5 AS v) SELECT v FROM mycte;
-- Error: duplicate names differing only in case.
WITH c AS (SELECT 1), C AS (SELECT 2) SELECT * FROM c;

-- Valid: VALUES as the main statement after WITH.
WITH c AS (SELECT 1) VALUES (10), (20);

-- Error: mutual recursion between two CTEs is not supported.
WITH RECURSIVE a(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM b WHERE x < 5), b(x) AS (SELECT x FROM a) SELECT x FROM a;

-- Valid: a runtime error inside a CTE fails the whole statement (sum
-- overflow), and no rows are printed for it.
WITH big(v) AS (VALUES (9223372036854775807), (1)) SELECT sum(v) FROM big;
WITH big(v) AS (VALUES (9223372036854775807), (1)) SELECT total(v) FROM big;

-- Valid: WITH before INSERT ... VALUES (the CTE is unused).
WITH c AS (SELECT 1) INSERT INTO t VALUES (3, 'z');
SELECT count(*) FROM t;

-- Valid: CTE used in LIMIT/OFFSET expressions via scalar subqueries.
WITH n AS (SELECT 2 AS k) SELECT a FROM t ORDER BY a LIMIT (SELECT k FROM n);
