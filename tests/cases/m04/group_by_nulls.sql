-- For grouping, all NULLs are equal: they form one group.
CREATE TABLE t(k, v INTEGER);
INSERT INTO t VALUES (NULL, 1), ('a', 2), (NULL, 3), ('b', 4), ('a', 5), (NULL, NULL);
SELECT k, count(*), count(v), sum(v) FROM t GROUP BY k ORDER BY k;
SELECT k, count(*) FROM t GROUP BY k ORDER BY k NULLS LAST;

-- Multi-column grouping with NULLs in either column.
CREATE TABLE m(a, b, n INTEGER);
INSERT INTO m VALUES (1, NULL, 1), (1, NULL, 2), (NULL, 1, 3), (NULL, NULL, 4), (NULL, NULL, 5), (1, 1, 6);
SELECT a, b, count(*), sum(n) FROM m GROUP BY a, b ORDER BY a, b;

-- Grouping by an expression that yields NULL.
SELECT v / 0, count(*) FROM t GROUP BY v / 0;
SELECT nullif(k, 'a'), count(*) FROM t GROUP BY nullif(k, 'a') ORDER BY 1;

-- A table where every key is NULL.
CREATE TABLE n(k, v INTEGER);
INSERT INTO n VALUES (NULL, 1), (NULL, 2), (NULL, 3);
SELECT k, sum(v), count(*) FROM n GROUP BY k;

-- NULL groups with HAVING.
SELECT k, count(*) FROM t GROUP BY k HAVING k IS NULL;
SELECT k, count(*) FROM t GROUP BY k HAVING k IS NOT NULL ORDER BY k;

-- coalesce to name the NULL group.
SELECT coalesce(k, '(none)') AS key, count(*) FROM t GROUP BY k ORDER BY key;
