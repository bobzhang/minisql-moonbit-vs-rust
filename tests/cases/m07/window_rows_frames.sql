-- ROWS frames with every kind of bound: UNBOUNDED PRECEDING, N PRECEDING,
-- CURRENT ROW, N FOLLOWING, UNBOUNDED FOLLOWING, in the BETWEEN form and
-- the short form (start only; the end is then CURRENT ROW).
-- Values are powers of two so each sum identifies exactly which rows are in
-- the frame.
CREATE TABLE r(id INTEGER PRIMARY KEY, g TEXT, v INTEGER);
INSERT INTO r VALUES (1, 'a', 1), (2, 'a', 2), (3, 'a', 4), (4, 'a', 8), (5, 'a', 16), (6, 'a', 32),
  (7, 'b', 64), (8, 'b', 128), (9, 'b', 256);

-- Short forms.
SELECT id, sum(v) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING), sum(v) OVER (ORDER BY id ROWS 2 PRECEDING),
  sum(v) OVER (ORDER BY id ROWS CURRENT ROW) FROM r ORDER BY id;

-- Start bounds combined with end = UNBOUNDED FOLLOWING.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND UNBOUNDED FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN 2 FOLLOWING AND UNBOUNDED FOLLOWING) FROM r ORDER BY id;

-- Symmetric and asymmetric windows around the current row.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 1 FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN CURRENT ROW AND 2 FOLLOWING) FROM r ORDER BY id;

-- Frames entirely before or after the current row.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 3 FOLLOWING),
  sum(v) OVER (ORDER BY id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) FROM r ORDER BY id;

-- Frames never cross partition boundaries.
SELECT id, g, sum(v) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING),
  sum(v) OVER (PARTITION BY g ORDER BY id ROWS BETWEEN 3 PRECEDING AND UNBOUNDED FOLLOWING) FROM r ORDER BY id;

-- Descending order: "preceding" rows are those with larger ids.
SELECT id, sum(v) OVER (ORDER BY id DESC ROWS 1 PRECEDING), sum(v) OVER (ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)
FROM r ORDER BY id;

-- 0 PRECEDING / 0 FOLLOWING are the current row.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 0 PRECEDING AND 0 FOLLOWING) FROM r WHERE g = 'b' ORDER BY id;

-- Offsets larger than the partition.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 100 PRECEDING AND 100 FOLLOWING) FROM r WHERE g = 'b' ORDER BY id;

-- Frame ending at UNBOUNDED PRECEDING... is not allowed, but a frame
-- starting at N FOLLOWING and ending at a larger N FOLLOWING is.
SELECT id, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING) FROM r ORDER BY id;

-- Several ROWS frames on different aggregates in one query.
SELECT id, count(*) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND 2 FOLLOWING), avg(v) OVER (ORDER BY id ROWS 1 PRECEDING),
  max(v) OVER (ORDER BY id ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING) FROM r ORDER BY id;

-- ROWS frame with an ORDER BY on a non-id column (unique values).
SELECT id, sum(v) OVER (ORDER BY v DESC ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM r ORDER BY id;

-- ROWS frame without ORDER BY but with both bounds unbounded is the whole
-- partition regardless of row order.
SELECT id, sum(v) OVER (PARTITION BY g ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM r ORDER BY id;

-- Keywords are case-insensitive.
SELECT id, sum(v) over (order by id rows between 1 preceding and current row) FROM r WHERE id <= 3 ORDER BY id;
