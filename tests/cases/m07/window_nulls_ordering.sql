-- NULLs in window ORDER BY and PARTITION BY: NULLs sort first ascending and
-- last descending by default, NULLS FIRST/LAST override that, NULL keys are
-- peers of each other, and NULL partition keys form one partition.
CREATE TABLE nl(id INTEGER PRIMARY KEY, g TEXT, k INTEGER, v INTEGER);
INSERT INTO nl VALUES (1, 'a', NULL, 1), (2, 'a', 3, 2), (3, NULL, 1, 4), (4, 'a', NULL, 8),
  (5, NULL, NULL, 16), (6, 'b', 2, 32), (7, 'b', 5, 64);

-- Default NULL placement in ascending / descending order.
SELECT id, k, rank() OVER (ORDER BY k), rank() OVER (ORDER BY k DESC) FROM nl ORDER BY id;

-- NULLS FIRST / NULLS LAST explicitly.
SELECT id, k, rank() OVER (ORDER BY k NULLS LAST), rank() OVER (ORDER BY k DESC NULLS FIRST) FROM nl ORDER BY id;

-- Running sums: NULL-key rows are peers, so they share a running total.
SELECT id, k, sum(v) OVER (ORDER BY k), sum(v) OVER (ORDER BY k NULLS LAST) FROM nl ORDER BY id;

-- row_number with NULL keys, made unique by a second key.
SELECT id, row_number() OVER (ORDER BY k, id), row_number() OVER (ORDER BY k DESC NULLS LAST, id DESC) FROM nl ORDER BY id;

-- NULL partition key: rows with g IS NULL form one partition.
SELECT id, g, count(*) OVER (PARTITION BY g), sum(v) OVER (PARTITION BY g) FROM nl ORDER BY id;

-- RANGE offsets with NULL keys: a NULL row's frame is exactly the NULL peers;
-- non-NULL rows never include NULL rows via an offset bound.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM nl ORDER BY id;
SELECT id, k, sum(v) OVER (ORDER BY k NULLS LAST RANGE BETWEEN 2 PRECEDING AND CURRENT ROW) FROM nl ORDER BY id;
-- ... but UNBOUNDED bounds do include them.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM nl ORDER BY id;

-- GROUPS: the NULLs form one group.
SELECT id, k, sum(v) OVER (ORDER BY k GROUPS BETWEEN CURRENT ROW AND 1 FOLLOWING) FROM nl ORDER BY id;

-- dense_rank, percent_rank and cume_dist with NULL peers.
SELECT id, dense_rank() OVER (ORDER BY k), percent_rank() OVER (ORDER BY k), cume_dist() OVER (ORDER BY k) FROM nl ORDER BY id;

-- lag/lead over a NULL-containing sort key (unique with id).
SELECT id, lag(id) OVER (ORDER BY k NULLS LAST, id), lead(id) OVER (ORDER BY k NULLS LAST, id) FROM nl ORDER BY id;

-- first_value / last_value picking NULL keys depending on NULLS placement.
SELECT DISTINCT first_value(k) OVER (ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING),
  first_value(k) OVER (ORDER BY k NULLS LAST ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM nl;

-- NULLs in the aggregated argument are skipped by sum/count(x).
SELECT id, count(k) OVER (ORDER BY id), sum(k) OVER (ORDER BY id) FROM nl ORDER BY id;
