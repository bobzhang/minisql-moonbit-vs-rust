-- EXCLUDE CURRENT ROW and EXCLUDE NO OTHERS with ROWS, RANGE and GROUPS
-- frames. Values are powers of two so each sum identifies the frame's rows.
CREATE TABLE x(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO x VALUES (1, 1, 1), (2, 2, 2), (3, 2, 4), (4, 3, 8), (5, 5, 16), (6, 5, 32);

-- EXCLUDE NO OTHERS is the default and changes nothing.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE NO OTHERS),
  sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM x ORDER BY id;

-- ROWS frame excluding the current row: the sum of the neighbours.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- Sum of all other rows in the partition.
SELECT id, sum(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- RANGE frames: peers of the current row stay, only the row itself goes.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND CURRENT ROW EXCLUDE CURRENT ROW),
  sum(v) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- GROUPS frames.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- Default-like RANGE frame with EXCLUDE (the frame must be spelled out).
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- count/avg/min/max with an excluded current row; a one-row frame becomes empty.
SELECT id, count(*) OVER w, avg(v) OVER w, min(v) OVER w, max(v) OVER w FROM x
WINDOW w AS (ORDER BY id ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING EXCLUDE CURRENT ROW) ORDER BY id;

-- first_value / last_value / nth_value skip the excluded row.
SELECT id, first_value(v) OVER w, last_value(v) OVER w, nth_value(v, 2) OVER w FROM x
WINDOW w AS (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) ORDER BY id;

-- group_concat with the current row excluded.
SELECT id, group_concat(id, '') OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING EXCLUDE CURRENT ROW) FROM x ORDER BY id;

-- Per partition.
SELECT id, k, sum(v) OVER (PARTITION BY k ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW)
FROM x ORDER BY id;

-- "Average of the other rows", a common use.
SELECT id, v, round(avg(v) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE CURRENT ROW), 2) FROM x ORDER BY id;

-- EXCLUDE does not affect functions that ignore frames.
SELECT id, row_number() OVER w, rank() OVER w, lag(id) OVER w FROM x
WINDOW w AS (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) ORDER BY id;

-- Error: EXCLUDE requires an explicit frame specification.
SELECT sum(v) OVER (ORDER BY id EXCLUDE CURRENT ROW) FROM x;
