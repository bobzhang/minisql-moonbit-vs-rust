-- A scalar subquery yields the first column of its first row; NULL when it
-- returns no rows. Extra rows are ignored.
CREATE TABLE t(id INTEGER PRIMARY KEY, v INTEGER, s TEXT);
INSERT INTO t VALUES (1, 30, 'c'), (2, 10, 'a'), (3, 20, 'b'), (4, NULL, NULL);

SELECT (SELECT 42);
SELECT (SELECT v FROM t WHERE id = 2);
-- Empty result: NULL.
SELECT (SELECT v FROM t WHERE id = 99);
SELECT (SELECT v FROM t WHERE id = 99) IS NULL, typeof((SELECT s FROM t WHERE 0));
-- Several rows: the first row in the subquery's own ORDER BY wins.
SELECT (SELECT v FROM t ORDER BY v DESC);
SELECT (SELECT v FROM t ORDER BY v);
SELECT (SELECT s FROM t WHERE s IS NOT NULL ORDER BY s DESC);
-- LIMIT / OFFSET inside the subquery pick another row.
SELECT (SELECT v FROM t ORDER BY v LIMIT 1 OFFSET 2);
SELECT (SELECT v FROM t ORDER BY v LIMIT 1 OFFSET 10);
-- Aggregates always produce one row, even over no input.
SELECT (SELECT count(*) FROM t), (SELECT max(v) FROM t), (SELECT sum(v) FROM t WHERE 0), (SELECT count(*) FROM t WHERE 0);
-- A NULL value in the first row is different from "no rows" but prints the same.
SELECT (SELECT v FROM t WHERE id = 4), (SELECT count(*) FROM t WHERE v IS (SELECT v FROM t WHERE id = 4));
-- The result keeps its type.
SELECT typeof((SELECT v FROM t WHERE id = 1)), typeof((SELECT s FROM t WHERE id = 1)), typeof((SELECT 1.5)), typeof((SELECT x'00'));
-- Scalar subqueries in the select list of a query over a table.
SELECT id, (SELECT max(v) FROM t) - coalesce(v, 0) FROM t ORDER BY id;
-- Scalar subquery in WHERE.
SELECT id FROM t WHERE v = (SELECT min(v) FROM t);
SELECT id FROM t WHERE v > (SELECT avg(v) FROM t) ORDER BY id;
-- Comparing with an empty subquery is NULL, so nothing matches.
SELECT count(*) FROM t WHERE v = (SELECT v FROM t WHERE 0);
-- A compound as a scalar subquery.
SELECT (SELECT 5 UNION SELECT 3 ORDER BY 1);
-- Nested scalar subqueries.
SELECT (SELECT (SELECT v FROM t WHERE id = 3) + 1);
-- Errors: more than one result column.
SELECT (SELECT id, v FROM t);
SELECT id FROM t WHERE v = (SELECT * FROM t);
