-- GROUP BY on expressions.
CREATE TABLE t(id INTEGER, name TEXT, score INTEGER, ts TEXT);
INSERT INTO t VALUES
  (1, 'Alice', 91, '2024-01-05'), (2, 'bob', 78, '2024-01-20'), (3, 'Carol', 85, '2024-02-02'),
  (4, 'dave', 62, '2024-02-14'), (5, 'Eve', 99, '2024-03-01'), (6, 'frank', 70, '2024-03-30'),
  (7, 'Gina', NULL, '2024-03-31');

-- Group by a computed bucket.
SELECT score / 10 * 10 AS bucket, count(*) FROM t GROUP BY score / 10 ORDER BY bucket;
-- Group by a substring (year-month).
SELECT substr(ts, 1, 7), count(*), max(score) FROM t GROUP BY substr(ts, 1, 7) ORDER BY 1;
-- Group by a boolean expression.
SELECT score >= 80, count(*) FROM t GROUP BY score >= 80 ORDER BY 1;
-- Group by CASE.
SELECT CASE WHEN score >= 90 THEN 'A' WHEN score >= 75 THEN 'B' ELSE 'C' END AS grade, count(*)
FROM t GROUP BY grade ORDER BY grade;
-- Group by a function of text.
SELECT length(name), group_concat(name, ',' ORDER BY name) FROM t GROUP BY length(name) ORDER BY 1;
SELECT upper(substr(name, 1, 1)) = substr(name, 1, 1) AS capital, count(*) FROM t GROUP BY 1 ORDER BY 1;

-- The selected expression may be built on the group expression.
SELECT id % 3, (id % 3) * 100 + count(*) FROM t GROUP BY id % 3 ORDER BY 1;

-- Group by a constant: a single group.
SELECT count(*), sum(score) FROM t GROUP BY 'constant';
-- Group by an expression that is NULL for some rows.
SELECT score / 20, count(*) FROM t GROUP BY score / 20 ORDER BY 1;

-- Selecting an aggregate of the grouping expression.
SELECT id % 2, sum(id % 2), count(*) FROM t GROUP BY id % 2 ORDER BY 1;

-- Grouping by an expression over two columns.
SELECT id + score > 90, count(*) FROM t GROUP BY id + score > 90 ORDER BY 1;
