-- AS MATERIALIZED / AS NOT MATERIALIZED are optimizer hints: they must be
-- parsed and must never change results.
CREATE TABLE t(id INTEGER PRIMARY KEY, grp TEXT, v INTEGER);
INSERT INTO t VALUES (1, 'x', 5), (2, 'x', 7), (3, 'y', 1), (4, 'y', NULL), (5, 'z', 9);

-- Same query three ways: no hint, MATERIALIZED, NOT MATERIALIZED.
WITH s AS (SELECT grp, sum(v) AS total FROM t GROUP BY grp) SELECT grp, total FROM s ORDER BY grp;
WITH s AS MATERIALIZED (SELECT grp, sum(v) AS total FROM t GROUP BY grp) SELECT grp, total FROM s ORDER BY grp;
WITH s AS NOT MATERIALIZED (SELECT grp, sum(v) AS total FROM t GROUP BY grp) SELECT grp, total FROM s ORDER BY grp;

-- Hints combined with a column list.
WITH s(g, n) AS MATERIALIZED (SELECT grp, count(*) FROM t GROUP BY grp) SELECT g, n FROM s ORDER BY g;
WITH s(g, n) AS NOT MATERIALIZED (SELECT grp, count(v) FROM t GROUP BY grp) SELECT g, n FROM s ORDER BY g;

-- A materialized CTE referenced twice (self-join).
WITH m AS MATERIALIZED (SELECT id, v FROM t WHERE v IS NOT NULL)
SELECT a.id, b.id FROM m a JOIN m b ON b.v = a.v + 2 ORDER BY a.id;

-- Mixed hints across several CTEs in one WITH.
WITH a AS MATERIALIZED (SELECT id FROM t WHERE grp = 'x'),
     b AS NOT MATERIALIZED (SELECT id FROM t WHERE grp = 'y'),
     c AS (SELECT id FROM a UNION ALL SELECT id FROM b)
SELECT id FROM c ORDER BY id;

-- Hints on a recursive CTE.
WITH RECURSIVE r(n) AS MATERIALIZED (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 5) SELECT sum(n) FROM r;
WITH RECURSIVE r(n) AS NOT MATERIALIZED (SELECT 1 UNION ALL SELECT n * 2 FROM r WHERE n < 100) SELECT max(n), count(*) FROM r;

-- Hints with a filter pushed from the outer query must not change the result.
WITH s AS NOT MATERIALIZED (SELECT id, v * 10 AS w FROM t) SELECT id, w FROM s WHERE w > 50 ORDER BY id;
WITH s AS MATERIALIZED (SELECT id, v * 10 AS w FROM t) SELECT id, w FROM s WHERE w > 50 ORDER BY id;

-- Hints in WITH ... UPDATE / DELETE.
WITH lo AS MATERIALIZED (SELECT id FROM t WHERE v < 6) UPDATE t SET v = v + 100 WHERE id IN lo;
WITH hi AS NOT MATERIALIZED (SELECT id FROM t WHERE v > 100) DELETE FROM t WHERE id IN hi;
SELECT id, v FROM t ORDER BY id;

-- Keywords are case-insensitive.
with s as not materialized (select 1 as one) select one from s;

-- Errors: malformed hints.
WITH s AS MATERIALISED (SELECT 1) SELECT * FROM s;
WITH s AS NOT (SELECT 1) SELECT * FROM s;
WITH s MATERIALIZED AS (SELECT 1) SELECT * FROM s;
