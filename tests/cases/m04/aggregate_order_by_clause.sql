-- ORDER BY inside an aggregate call sets the order in which values are fed
-- to it. This matters for group_concat/string_agg; for other aggregates it is
-- accepted and has no visible effect.
CREATE TABLE t(id INTEGER, g TEXT, name TEXT, score INTEGER);
INSERT INTO t VALUES
  (1, 'x', 'mia', 3), (2, 'x', 'al', 9), (3, 'y', 'zoe', 1), (4, 'x', 'bo', 9),
  (5, 'y', 'cy', NULL), (6, 'y', 'Di', 5), (7, 'z', NULL, 2);

SELECT group_concat(name ORDER BY name) FROM t;
SELECT group_concat(name ORDER BY name DESC) FROM t;
-- Several keys, mixed directions.
SELECT group_concat(name ORDER BY score DESC, name ASC) FROM t;
-- NULLS FIRST/LAST inside the aggregate.
SELECT group_concat(name, ',' ORDER BY score NULLS FIRST, id) FROM t;
SELECT group_concat(name, ',' ORDER BY score DESC NULLS LAST, id) FROM t;
-- COLLATE inside the aggregate.
SELECT group_concat(name ORDER BY name COLLATE NOCASE) FROM t;
-- Order by an expression not otherwise used.
SELECT group_concat(name ORDER BY length(name), name) FROM t;
SELECT group_concat(id ORDER BY id % 3, id DESC) FROM t;

-- Per group.
SELECT g, group_concat(name, '/' ORDER BY score, name) FROM t GROUP BY g ORDER BY g;

-- ORDER BY in other aggregates does not change the result.
SELECT sum(score ORDER BY score DESC), count(name ORDER BY name), min(score ORDER BY id), max(name ORDER BY score) FROM t;
SELECT avg(score ORDER BY name), total(score ORDER BY id DESC) FROM t;

-- Combined with DISTINCT and FILTER.
SELECT group_concat(DISTINCT g ORDER BY g DESC) FROM t;
SELECT group_concat(name ORDER BY id DESC) FILTER (WHERE score > 2) FROM t;

-- ORDER BY on a value of a different type from the aggregated one.
SELECT group_concat(score, '-' ORDER BY name) FROM t WHERE score IS NOT NULL;

-- ORDER BY inside a non-aggregate function is an error.
SELECT upper(name ORDER BY name) FROM t;
