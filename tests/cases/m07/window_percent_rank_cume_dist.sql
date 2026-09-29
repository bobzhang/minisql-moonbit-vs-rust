-- percent_rank() = (rank - 1) / (partition rows - 1), 0.0 for a single row;
-- cume_dist() = (rows up to and including the last peer) / partition rows.
-- Both return REAL.
CREATE TABLE p(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO p VALUES (1, 'x', 10), (2, 'x', 20), (3, 'x', 20), (4, 'x', 30), (5, 'x', 40),
  (6, 'y', 5), (7, 'z', 1), (8, 'z', 1), (9, 'z', 2), (10, 'z', NULL);

SELECT id, v, percent_rank() OVER (ORDER BY v), cume_dist() OVER (ORDER BY v) FROM p WHERE g = 'x' ORDER BY id;

-- Per partition; the one-row partition gives 0.0 and 1.0.
SELECT id, g, v, percent_rank() OVER (PARTITION BY g ORDER BY v), cume_dist() OVER (PARTITION BY g ORDER BY v)
FROM p ORDER BY id;

-- Descending order.
SELECT id, v, percent_rank() OVER (ORDER BY v DESC), cume_dist() OVER (ORDER BY v DESC) FROM p WHERE g = 'x' ORDER BY id;

-- No ORDER BY: all rows are peers.
SELECT id, percent_rank() OVER (PARTITION BY g), cume_dist() OVER (PARTITION BY g) FROM p ORDER BY id;

-- Result types.
SELECT DISTINCT typeof(percent_rank() OVER (ORDER BY v)), typeof(cume_dist() OVER (ORDER BY v)) FROM p;

-- Expressions over the results; percentile buckets.
SELECT id, CAST(percent_rank() OVER (ORDER BY v) * 100 AS INTEGER) FROM p WHERE g = 'x' ORDER BY id;
SELECT id, cume_dist() OVER (ORDER BY v) <= 0.5 FROM p WHERE g = 'x' ORDER BY id;

-- Relationship with rank(): percent_rank * (n - 1) + 1 = rank.
SELECT id, rank() OVER w, percent_rank() OVER w * 4 + 1 FROM p WHERE g = 'x' WINDOW w AS (ORDER BY v) ORDER BY id;

-- The whole table: 10 rows, NULL first.
SELECT id, v, percent_rank() OVER (ORDER BY v), cume_dist() OVER (ORDER BY v) FROM p ORDER BY id;

-- cume_dist of the last peer group is always 1.0.
SELECT g, max(cd) FROM (SELECT g, cume_dist() OVER (PARTITION BY g ORDER BY v) AS cd FROM p) GROUP BY g ORDER BY g;

-- Errors: these functions take no arguments.
SELECT percent_rank(v) OVER (ORDER BY v) FROM p;
SELECT cume_dist(1) OVER (ORDER BY v) FROM p;
