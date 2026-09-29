-- [NOT] EXISTS (SELECT ...) is 1 if the subquery returns at least one row,
-- else 0. It is never NULL, and what the subquery selects does not matter.
CREATE TABLE t(v INTEGER);
CREATE TABLE empty_t(v INTEGER);
INSERT INTO t VALUES (1), (2), (NULL);

SELECT EXISTS (SELECT 1 FROM t), EXISTS (SELECT 1 FROM empty_t);
SELECT NOT EXISTS (SELECT 1 FROM t), NOT EXISTS (SELECT 1 FROM empty_t);
-- Rows made of NULLs still count as rows.
SELECT EXISTS (SELECT NULL), EXISTS (SELECT v FROM t WHERE v IS NULL);
-- The select list is irrelevant, even * or several columns.
SELECT EXISTS (SELECT * FROM t), EXISTS (SELECT v, v + 1, 'x' FROM t WHERE v = 2);
-- WHERE that filters everything.
SELECT EXISTS (SELECT 1 FROM t WHERE v > 100), EXISTS (SELECT 1 FROM t WHERE NULL);
-- An aggregate without GROUP BY always yields a row.
SELECT EXISTS (SELECT count(*) FROM empty_t), EXISTS (SELECT max(v) FROM empty_t);
-- With GROUP BY over no rows there are no groups.
SELECT EXISTS (SELECT count(*) FROM empty_t GROUP BY v);
-- HAVING can eliminate the only row.
SELECT EXISTS (SELECT count(*) FROM t HAVING count(*) > 10);
-- LIMIT 0 yields no rows.
SELECT EXISTS (SELECT 1 FROM t LIMIT 0);
-- Type of the result.
SELECT typeof(EXISTS (SELECT 1)), EXISTS (SELECT 1) + EXISTS (SELECT 1 FROM t);
-- Uncorrelated EXISTS in WHERE keeps all rows or none.
SELECT v FROM t WHERE EXISTS (SELECT 1 FROM t WHERE v = 2) ORDER BY v;
SELECT v FROM t WHERE EXISTS (SELECT 1 FROM empty_t);
SELECT count(*) FROM t WHERE NOT EXISTS (SELECT 1 FROM empty_t);
-- EXISTS over a compound query.
SELECT EXISTS (SELECT 1 FROM t INTERSECT SELECT 1), EXISTS (SELECT 5 INTERSECT SELECT v FROM t);
-- EXISTS in CASE and arithmetic.
SELECT CASE WHEN EXISTS (SELECT 1 FROM t WHERE v = 1) THEN 'has 1' ELSE 'no 1' END;
-- EXISTS over a join.
SELECT EXISTS (SELECT 1 FROM t a JOIN t b ON a.v = b.v + 1);
