-- PARTITION BY: one or several expressions; functions restart for each
-- partition and frames stay inside it.
CREATE TABLE pb(id INTEGER PRIMARY KEY, a TEXT, b INTEGER, v INTEGER);
INSERT INTO pb VALUES (1, 'x', 1, 10), (2, 'x', 2, 20), (3, 'y', 1, 30), (4, 'x', 1, 40),
  (5, 'y', 2, 50), (6, 'y', 1, 60), (7, 'X', 1, 70);

-- Single column.
SELECT id, a, row_number() OVER (PARTITION BY a ORDER BY id), sum(v) OVER (PARTITION BY a) FROM pb ORDER BY id;

-- Two columns.
SELECT id, a, b, count(*) OVER (PARTITION BY a, b), sum(v) OVER (PARTITION BY a, b ORDER BY id) FROM pb ORDER BY id;

-- Expression partitions.
SELECT id, v, sum(v) OVER (PARTITION BY v > 30), count(*) OVER (PARTITION BY id % 2) FROM pb ORDER BY id;

-- Partition by a collated expression: 'x' and 'X' together under NOCASE.
SELECT id, a, count(*) OVER (PARTITION BY a COLLATE NOCASE), count(*) OVER (PARTITION BY a) FROM pb ORDER BY id;

-- Partitioning by a declared NOCASE column uses that collation.
CREATE TABLE ci(id INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE);
INSERT INTO ci VALUES (1, 'Ann'), (2, 'ann'), (3, 'ANN'), (4, 'bob');
SELECT id, count(*) OVER (PARTITION BY name), row_number() OVER (PARTITION BY name ORDER BY id) FROM ci ORDER BY id;

-- Partition by a constant: one partition.
SELECT id, count(*) OVER (PARTITION BY 1) FROM pb WHERE id <= 3 ORDER BY id;

-- Partition values of different types are different partitions (1 vs '1').
CREATE TABLE mix(id INTEGER PRIMARY KEY, p);
INSERT INTO mix VALUES (1, 1), (2, '1'), (3, 1.0), (4, x'31'), (5, 1);
SELECT id, typeof(p), count(*) OVER (PARTITION BY p) FROM mix ORDER BY id;

-- Every partition's running sum restarts; frames do not leak across partitions.
SELECT id, b, sum(v) OVER (PARTITION BY b ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM pb ORDER BY id;

-- Many small partitions: each row alone.
SELECT id, count(*) OVER (PARTITION BY id), rank() OVER (PARTITION BY id ORDER BY v) FROM pb ORDER BY id;

-- Partition by a subquery-derived value.
SELECT id, v, sum(v) OVER (PARTITION BY v > (SELECT avg(v) FROM pb)) FROM pb ORDER BY id;

-- Different partitionings in one query.
SELECT id, sum(v) OVER (PARTITION BY a), sum(v) OVER (PARTITION BY b), sum(v) OVER () FROM pb ORDER BY id;

-- Partition by a column not in the select list.
SELECT id, max(v) OVER (PARTITION BY b) FROM pb ORDER BY id;
