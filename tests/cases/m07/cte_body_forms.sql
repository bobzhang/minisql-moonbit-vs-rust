-- Different kinds of CTE bodies: VALUES, compound selects, joins, ORDER BY
-- with LIMIT/OFFSET, DISTINCT; and a WITH whose main query is a compound.
CREATE TABLE a(k INTEGER, s TEXT);
CREATE TABLE b(k INTEGER, t TEXT);
INSERT INTO a VALUES (1, 'a1'), (2, 'a2'), (3, 'a3'), (4, 'a4');
INSERT INTO b VALUES (2, 'b2'), (3, 'b3'), (5, 'b5');

-- VALUES body with mixed types.
WITH v(x) AS (VALUES (1), (2.5), ('three'), (NULL), (x'04'))
SELECT x, typeof(x) FROM v ORDER BY x;

-- UNION / UNION ALL / INTERSECT / EXCEPT bodies.
WITH u(k) AS (SELECT k FROM a UNION SELECT k FROM b) SELECT group_concat(k, ',' ORDER BY k) FROM u;
WITH u(k) AS (SELECT k FROM a UNION ALL SELECT k FROM b) SELECT count(*), sum(k) FROM u;
WITH u(k) AS (SELECT k FROM a INTERSECT SELECT k FROM b) SELECT k FROM u ORDER BY k;
WITH u(k) AS (SELECT k FROM a EXCEPT SELECT k FROM b) SELECT k FROM u ORDER BY k;

-- Compound body with its own ORDER BY / LIMIT (applies to the compound).
WITH u(k) AS (SELECT k FROM a UNION SELECT k FROM b ORDER BY 1 DESC LIMIT 2) SELECT k FROM u ORDER BY k;

-- Join bodies.
WITH j AS (SELECT a.k, a.s, b.t FROM a JOIN b ON a.k = b.k) SELECT k, s, t FROM j ORDER BY k;
WITH j AS (SELECT a.k, b.t FROM a LEFT JOIN b ON a.k = b.k) SELECT k, t FROM j ORDER BY k;

-- ORDER BY + LIMIT + OFFSET in the body.
WITH w AS (SELECT k FROM a ORDER BY k DESC LIMIT 2 OFFSET 1) SELECT k FROM w ORDER BY k;

-- DISTINCT body.
WITH d AS (SELECT DISTINCT k % 2 AS parity FROM a) SELECT parity FROM d ORDER BY parity;

-- Main query is a compound that references the CTE in several arms.
WITH c AS (SELECT k FROM a WHERE k <= 2)
SELECT k FROM c UNION ALL SELECT k * 100 FROM c ORDER BY 1;

-- Main query compound mixing CTE and table.
WITH c AS (SELECT k FROM b) SELECT k FROM a EXCEPT SELECT k FROM c ORDER BY k;

-- A multi-column VALUES body.
WITH p(x, y) AS (VALUES (1, 'one'), (2, 'two')) SELECT y, x FROM p ORDER BY x DESC;

-- Subquery in FROM of a CTE body.
WITH s AS (SELECT q.k FROM (SELECT k FROM a WHERE k > 1) AS q WHERE q.k < 4) SELECT k FROM s ORDER BY k;

-- A body that returns no rows.
WITH e AS (SELECT k FROM a WHERE 0) SELECT count(*), max(k) FROM e;

-- Error: compound arms with different column counts inside a CTE body.
WITH bad AS (SELECT k FROM a UNION SELECT k, t FROM b) SELECT * FROM bad;
