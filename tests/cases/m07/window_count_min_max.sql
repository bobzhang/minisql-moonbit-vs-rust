-- count(*), count(x), min() and max() as window functions over various
-- frames, including NULLs and mixed types.
CREATE TABLE c(id INTEGER PRIMARY KEY, g TEXT, v);
INSERT INTO c VALUES (1, 'p', 5), (2, 'p', NULL), (3, 'p', 3), (4, 'p', 8), (5, 'q', 'text'),
  (6, 'q', 2.5), (7, 'q', NULL), (8, 'q', x'01'), (9, 'r', NULL);

-- count(*) counts rows, count(v) non-NULL values.
SELECT id, count(*) OVER (ORDER BY id), count(v) OVER (ORDER BY id) FROM c ORDER BY id;
SELECT id, g, count(*) OVER (PARTITION BY g), count(v) OVER (PARTITION BY g) FROM c ORDER BY id;

-- Running min and max.
SELECT id, min(v) OVER (PARTITION BY g ORDER BY id), max(v) OVER (PARTITION BY g ORDER BY id) FROM c ORDER BY id;

-- min/max use the cross-type order NULL < numbers < text < blob; NULLs are ignored.
SELECT g, min(v) OVER (PARTITION BY g), max(v) OVER (PARTITION BY g) FROM c WHERE g = 'q' AND id = 5;

-- Sliding window min/max: the extreme value must leave the frame again.
CREATE TABLE s(i INTEGER PRIMARY KEY, x INTEGER);
INSERT INTO s VALUES (1, 4), (2, 9), (3, 1), (4, 7), (5, 3), (6, 8), (7, 2), (8, 6);
SELECT i, min(x) OVER w, max(x) OVER w FROM s WINDOW w AS (ORDER BY i ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) ORDER BY i;
SELECT i, min(x) OVER w, max(x) OVER w FROM s WINDOW w AS (ORDER BY i ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) ORDER BY i;
SELECT i, min(x) OVER w, max(x) OVER w, count(*) OVER w FROM s WINDOW w AS (ORDER BY i ROWS BETWEEN CURRENT ROW AND 3 FOLLOWING) ORDER BY i;

-- Count of rows in a sliding frame at the edges of the partition.
SELECT i, count(*) OVER (ORDER BY i ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING) FROM s ORDER BY i;

-- Running count distinguishes duplicates via peers (RANGE default frame).
CREATE TABLE d(id INTEGER PRIMARY KEY, k INTEGER);
INSERT INTO d VALUES (1, 1), (2, 1), (3, 2), (4, 3), (5, 3), (6, 3);
SELECT id, count(*) OVER (ORDER BY k), max(id) OVER (ORDER BY k) FROM d ORDER BY id;

-- count(*) OVER () equals the total number of rows on every row.
SELECT DISTINCT count(*) OVER () FROM c;

-- Max of a text column with a collation-free comparison.
CREATE TABLE w(id INTEGER PRIMARY KEY, word TEXT);
INSERT INTO w VALUES (1, 'pear'), (2, 'Apple'), (3, 'banana'), (4, 'apple');
SELECT id, min(word) OVER (ORDER BY id), max(word) OVER (ORDER BY id) FROM w ORDER BY id;

-- min/max with an expression argument.
SELECT i, max(x * (i % 2)) OVER (ORDER BY i ROWS 2 PRECEDING) FROM s ORDER BY i;

-- Errors: count with two arguments; min/max with no arguments.
SELECT count(v, v) OVER () FROM c;
SELECT max() OVER () FROM c;
