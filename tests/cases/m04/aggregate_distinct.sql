-- DISTINCT inside aggregates: duplicates (after NULL removal) are dropped
-- before aggregating.
CREATE TABLE t(g TEXT, v INTEGER);
INSERT INTO t VALUES ('a', 1), ('a', 1), ('a', 2), ('a', NULL), ('b', 3), ('b', 3), ('b', 3), ('c', NULL);
SELECT count(DISTINCT v), sum(DISTINCT v), avg(DISTINCT v), total(DISTINCT v) FROM t;
SELECT count(v), sum(v), avg(v), total(v) FROM t;
SELECT min(DISTINCT v), max(DISTINCT v) FROM t;
SELECT group_concat(DISTINCT v ORDER BY v) FROM t;

-- Grouped.
SELECT g, count(DISTINCT v), sum(DISTINCT v), group_concat(DISTINCT v) FROM t GROUP BY g ORDER BY g;

-- DISTINCT on an expression.
SELECT count(DISTINCT v % 2), sum(DISTINCT v * 10) FROM t;

-- DISTINCT text with a collation.
CREATE TABLE s(w TEXT COLLATE NOCASE);
INSERT INTO s VALUES ('x'), ('y'), ('Y'), ('z'), ('y');
SELECT count(DISTINCT w), count(DISTINCT w COLLATE BINARY), count(DISTINCT upper(w)) FROM s;

-- DISTINCT on reals.
CREATE TABLE r(v REAL);
INSERT INTO r VALUES (0.5), (0.5), (1.5), (NULL);
SELECT sum(DISTINCT v), avg(DISTINCT v), count(DISTINCT v) FROM r;

-- Empty input.
SELECT sum(DISTINCT v), count(DISTINCT v), group_concat(DISTINCT v) FROM t WHERE g = 'none';

-- group_concat(DISTINCT x, sep) is not allowed: DISTINCT aggregates take
-- exactly one argument.
SELECT group_concat(DISTINCT v, ';') FROM t;
-- ALL is accepted and means the default.
SELECT count(ALL v), sum(ALL v) FROM t;
