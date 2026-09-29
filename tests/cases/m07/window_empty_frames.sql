-- Frames that contain no rows: aggregates return their empty-input value
-- (count 0, sum/avg/min/max/group_concat NULL, total 0.0) and the value
-- functions return NULL.
CREATE TABLE ef(id INTEGER PRIMARY KEY, v INTEGER);
INSERT INTO ef VALUES (1, 10), (2, 20), (3, 30), (4, 40);

-- A frame entirely before the current row is empty for the first row.
SELECT id, count(*) OVER w, sum(v) OVER w, avg(v) OVER w, total(v) OVER w, min(v) OVER w, max(v) OVER w, group_concat(v) OVER w
FROM ef WINDOW w AS (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING) ORDER BY id;

-- A frame entirely after the current row is empty for the last row.
SELECT id, count(v) OVER w, sum(v) OVER w, first_value(v) OVER w, last_value(v) OVER w, nth_value(v, 1) OVER w
FROM ef WINDOW w AS (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) ORDER BY id;

-- A start bound after the end bound gives an empty frame (not an error)
-- when both are offsets of the same direction.
SELECT id, count(*) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 2 PRECEDING), sum(v) OVER (ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING)
FROM ef ORDER BY id;

-- RANGE frames with no values in range.
CREATE TABLE sp(id INTEGER PRIMARY KEY, k INTEGER);
INSERT INTO sp VALUES (1, 0), (2, 10), (3, 11), (4, 30);
SELECT id, count(*) OVER (ORDER BY k RANGE BETWEEN 5 PRECEDING AND 1 PRECEDING), sum(k) OVER (ORDER BY k RANGE BETWEEN 1 FOLLOWING AND 5 FOLLOWING)
FROM sp ORDER BY id;

-- GROUPS frames beyond the last group.
SELECT id, count(*) OVER (ORDER BY k GROUPS BETWEEN 1 FOLLOWING AND 1 FOLLOWING), max(k) OVER (ORDER BY k GROUPS BETWEEN 2 PRECEDING AND 2 PRECEDING)
FROM sp ORDER BY id;

-- EXCLUDE making a one-row frame empty.
SELECT id, count(*) OVER w, sum(v) OVER w, total(v) OVER w FROM ef WINDOW w AS (ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW) ORDER BY id;

-- Empty frame with FILTER: nothing passes the filter.
SELECT id, count(*) FILTER (WHERE v > 100) OVER (ORDER BY id), sum(v) FILTER (WHERE v > 100) OVER (ORDER BY id) FROM ef ORDER BY id;

-- An empty table: window queries return no rows, and an aggregate over the
-- window query returns one row.
CREATE TABLE empty(id INTEGER PRIMARY KEY, v INTEGER);
SELECT id, sum(v) OVER (ORDER BY id), row_number() OVER () FROM empty;
SELECT count(*) FROM (SELECT rank() OVER (ORDER BY v) FROM empty);

-- A single row: every frame that includes the current row contains exactly it.
INSERT INTO empty VALUES (1, 5);
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 5 PRECEDING AND 5 FOLLOWING), rank() OVER (ORDER BY v), percent_rank() OVER (ORDER BY v),
  cume_dist() OVER (ORDER BY v), ntile(3) OVER (ORDER BY v), lag(v) OVER (ORDER BY v), lead(v, 1, 'none') OVER (ORDER BY v) FROM empty;
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING), first_value(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM empty;
