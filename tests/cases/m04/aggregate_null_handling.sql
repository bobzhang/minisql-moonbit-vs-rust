-- NULLs are ignored by every aggregate except count(*).
CREATE TABLE t(k INTEGER, v, s TEXT);
INSERT INTO t VALUES (1, NULL, NULL), (2, 4, 'b'), (3, NULL, 'a'), (4, 6, NULL), (5, NULL, NULL);
SELECT count(*), count(v), count(s) FROM t;
SELECT sum(v), total(v), avg(v), min(v), max(v) FROM t;
SELECT group_concat(s ORDER BY s), min(s), max(s) FROM t;

-- Only NULLs.
SELECT sum(v), total(v), avg(v), min(v), max(v), count(v), group_concat(v) FROM t WHERE v IS NULL;

-- NULL produced by an expression.
SELECT count(v / 0), sum(v / 0), max(v / 0), total(v / 0) FROM t;
SELECT count(nullif(v, 4)), sum(nullif(v, 4)) FROM t;

-- Aggregating a NULL literal.
SELECT count(NULL), sum(NULL), avg(NULL), max(NULL), group_concat(NULL) FROM t;

-- NULL groups.
SELECT s, count(*), sum(v) FROM t GROUP BY s ORDER BY s;

-- coalesce inside and outside.
SELECT sum(coalesce(v, 0)), avg(coalesce(v, 0)), count(coalesce(v, 0)) FROM t;
SELECT coalesce(max(s), '-') FROM t WHERE k IN (1, 5);

-- NULL in FILTER and CASE.
SELECT count(*) FILTER (WHERE v > 0), count(*) FILTER (WHERE v IS NULL) FROM t;
SELECT sum(CASE WHEN v IS NULL THEN 1 ELSE 0 END) FROM t;
