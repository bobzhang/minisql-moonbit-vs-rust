-- VALUES (...), (...) as a stand-alone query: one output row per tuple, in
-- the order written.
VALUES (1);
VALUES (1, 'a');
VALUES (1, 'a'), (2, 'b'), (3, 'c');
-- Any expression may appear in a tuple, including NULL, blobs, reals and subqueries.
VALUES (NULL, x'CAFE', 2.5, -0);
VALUES (1 + 2 * 3, upper('abc') || 'd', abs(-4), CASE WHEN 1 THEN 'yes' END);
VALUES ((SELECT 40 + 2));
-- Different rows may hold different types in the same column.
VALUES (1), ('one'), (1.5), (NULL);
-- Each row keeps its own storage class.
SELECT typeof(column1) FROM (VALUES (1), ('1'), (1.0), (NULL), (x'01')) ORDER BY 1;
-- Tuples referring to a table through subqueries.
CREATE TABLE t(v INTEGER);
INSERT INTO t VALUES (10), (20), (30);
VALUES ((SELECT min(v) FROM t), (SELECT max(v) FROM t)), ((SELECT count(*) FROM t), (SELECT sum(v) FROM t));
-- VALUES as a scalar subquery: first row's first column.
SELECT (VALUES (7)), (VALUES (8), (9));
-- VALUES as an IN list source and in EXISTS.
SELECT 20 IN (VALUES (10), (20)), 25 IN (VALUES (10), (20)), 5 NOT IN (VALUES (1), (NULL));
SELECT v FROM t WHERE v IN (VALUES (30), (10)) ORDER BY v;
SELECT EXISTS (VALUES (NULL));
-- VALUES as the source of INSERT with many rows.
INSERT INTO t VALUES (40), (50);
SELECT count(*), sum(v) FROM t;
-- Errors: rows of different lengths; unknown column reference inside VALUES.
VALUES (1, 2), (3);
VALUES (1), (2, 3);
VALUES (nosuch);
