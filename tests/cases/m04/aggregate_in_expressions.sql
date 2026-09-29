-- Aggregates can be combined with arithmetic, functions, CASE and each other
-- in the result list, and wrapped around arbitrary expressions.
CREATE TABLE t(g TEXT, a INTEGER, b REAL);
INSERT INTO t VALUES ('x', 1, 0.5), ('x', 2, 1.5), ('x', 3, NULL), ('y', 10, 2.0), ('y', 20, 4.0), ('z', NULL, NULL);

SELECT g, sum(a) * 2, sum(a) + count(*), max(a) - min(a) FROM t GROUP BY g ORDER BY g;
SELECT g, round(avg(b), 1), abs(-sum(a)), typeof(sum(a) / count(*)) FROM t GROUP BY g ORDER BY g;
SELECT g, CASE WHEN count(a) > 2 THEN 'many' WHEN count(a) = 0 THEN 'none' ELSE 'few' END FROM t GROUP BY g ORDER BY g;
SELECT g, coalesce(sum(a), -1), ifnull(max(b), 0.0) FROM t GROUP BY g ORDER BY g;
SELECT g, sum(a) / count(a), sum(a) * 1.0 / count(a) FROM t WHERE a IS NOT NULL GROUP BY g ORDER BY g;

-- Aggregates of expressions.
SELECT sum(a * b), sum(a) * sum(b), max(a + b), min(a || '-' || b) FROM t;
SELECT count(CASE WHEN a > 1 THEN 1 END), sum(CASE WHEN g = 'x' THEN a ELSE 0 END) FROM t;
SELECT max(length(g || a)), group_concat(a * 10, ',' ORDER BY a) FROM t;

-- Scalar functions over aggregate results.
SELECT printf('%d rows, avg %.2f', count(*), avg(a)) FROM t;
SELECT max(sum(a), 5) FROM t GROUP BY g ORDER BY 1;
SELECT min(max(a), 15) FROM t GROUP BY g ORDER BY 1;
SELECT upper(group_concat(g, '' ORDER BY a)) FROM t;

-- Comparing aggregates in the result.
SELECT g, sum(a) > 5, max(b) = 4.0, count(*) = count(a) FROM t GROUP BY g ORDER BY g;

-- Grouping column mixed with aggregates in one expression.
SELECT g || ':' || count(*) FROM t GROUP BY g ORDER BY 1;

-- The same aggregate used several times.
SELECT sum(a), sum(a) + sum(a), sum(a) * sum(a) FROM t;
