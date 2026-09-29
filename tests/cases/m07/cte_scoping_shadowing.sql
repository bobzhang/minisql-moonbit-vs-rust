-- Name resolution for CTEs: a CTE shadows a real table of the same name,
-- nested WITH clauses shadow outer CTEs, and CTEs are visible inside
-- subqueries of the statement they belong to.
CREATE TABLE items(id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO items VALUES (1, 'real1'), (2, 'real2'), (3, 'real3');

-- The CTE named like a table wins inside this statement ...
WITH items AS (SELECT 100 AS id, 'cte' AS name) SELECT id, name FROM items;
-- ... but the table is untouched afterwards.
SELECT id, name FROM items ORDER BY id;

-- A different CTE name can read the table and transform it.
WITH items2 AS (SELECT id * 10 AS id, upper(name) AS name FROM items)
SELECT id, name FROM items2 ORDER BY id;

-- CTEs are visible in scalar subqueries, IN and EXISTS of the main query.
WITH c AS (SELECT 2 AS k)
SELECT id, (SELECT k FROM c), id IN (SELECT k FROM c), EXISTS (SELECT 1 FROM c WHERE k = id)
FROM items ORDER BY id;

-- A WITH clause inside a subquery.
SELECT id, (WITH x AS (SELECT count(*) AS n FROM items) SELECT n FROM x) FROM items WHERE id = 1;

-- A WITH in a FROM-subquery; the inner CTE is local to that subquery.
SELECT s.v FROM (WITH inner_cte AS (SELECT 5 AS v UNION ALL SELECT 6) SELECT v FROM inner_cte) AS s ORDER BY s.v;

-- An inner WITH shadows an outer CTE of the same name.
WITH c AS (SELECT 'outer' AS w)
SELECT w, (WITH c AS (SELECT 'inner' AS w) SELECT w FROM c) FROM c;

-- The outer CTE is visible inside nested subqueries at any depth.
WITH c AS (SELECT 3 AS k)
SELECT name FROM items WHERE id = (SELECT k FROM (SELECT k FROM c));

-- A correlated subquery that reads a CTE.
WITH lim AS (SELECT 1 AS lo, 2 AS hi)
SELECT id, (SELECT count(*) FROM lim WHERE items.id BETWEEN lo AND hi) FROM items ORDER BY id;

-- Inner CTE referencing an outer CTE.
WITH o AS (SELECT 10 AS v)
SELECT (WITH i AS (SELECT v + 1 AS w FROM o) SELECT w FROM i);

-- Error: an inner CTE whose body uses its own name does not see the outer
-- CTE of that name; it is a circular reference.
WITH c AS (SELECT 1 AS x) SELECT (WITH c AS (SELECT x + 1 AS x FROM c) SELECT x FROM c);

-- A CTE shadows a view too.
CREATE VIEW vw AS SELECT 'view' AS src;
WITH vw AS (SELECT 'cte' AS src) SELECT src FROM vw;
SELECT src FROM vw;

-- Error: an inner CTE is not visible to the outer query.
SELECT * FROM (WITH hidden AS (SELECT 1 AS z) SELECT z FROM hidden) , hidden;
-- Error: a CTE whose body refers to its own name (without a recursive
-- UNION structure) is a circular reference, not a read of the real table.
WITH items AS (SELECT id * 10 AS id FROM items) SELECT id FROM items;
-- Error: CTE from a previous statement is gone.
SELECT * FROM c;
