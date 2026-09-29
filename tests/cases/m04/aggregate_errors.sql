-- Misuse of aggregates is an error. Each error statement is paired with a
-- valid variant.
CREATE TABLE t(g TEXT, v INTEGER);
INSERT INTO t VALUES ('a', 1), ('a', 2), ('b', 3);

-- Aggregate in WHERE.
SELECT count(*) FROM t WHERE sum(v) > 1;
SELECT count(*) FROM t WHERE v > 1;

-- Nested aggregates.
SELECT sum(max(v)) FROM t;
SELECT sum(v) + max(v) FROM t;

-- Aggregate in GROUP BY.
SELECT g FROM t GROUP BY sum(v);
SELECT g, sum(v) FROM t GROUP BY g ORDER BY g;

-- Wrong number of arguments.
SELECT count(v, v) FROM t;
SELECT count(v), sum(v), avg(v) FROM t;

-- FILTER with a non-aggregate function.
SELECT abs(v) FILTER (WHERE v > 1) FROM t;
SELECT DISTINCT abs(v) FROM t ORDER BY 1;

-- Unknown column inside an aggregate or in GROUP BY.
SELECT sum(nosuch) FROM t;

-- Aggregates in an UPDATE SET or DELETE WHERE are errors.
UPDATE t SET v = max(v);
DELETE FROM t WHERE v = min(v);
SELECT g, v FROM t ORDER BY g, v;

-- Aggregates are fine in ORDER BY of an aggregate query.
SELECT g, count(*) FROM t GROUP BY g ORDER BY count(*) DESC, g;
SELECT g FROM t GROUP BY g ORDER BY sum(v), g DESC;
SELECT count(*) FROM t;
SELECT max(v) FROM t;
SELECT min(g) FROM t;
SELECT total(v) FROM t;
SELECT group_concat(g, '' ORDER BY v) FROM t;
SELECT g, avg(v) FROM t GROUP BY g HAVING avg(v) > 1 ORDER BY g;
SELECT g, max(v) - min(v) FROM t GROUP BY g ORDER BY g;
SELECT sum(v) * count(*) FROM t;
SELECT count(*) FROM t WHERE g = 'a';
SELECT count(DISTINCT g) FROM t;
SELECT g, count(*) AS c FROM t GROUP BY g HAVING c < 2;
SELECT avg(v) * 2 FROM t;
SELECT g, v FROM t ORDER BY v DESC LIMIT 1;
SELECT g, sum(v) FILTER (WHERE v > 1) FROM t GROUP BY g ORDER BY g;
