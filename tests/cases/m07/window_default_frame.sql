-- Default frames. Without ORDER BY the frame is the whole partition; with
-- ORDER BY it is RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW, which
-- includes all peers of the current row (rows with equal ORDER BY values).
CREATE TABLE df(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO df VALUES (1, 1, 10), (2, 2, 20), (3, 2, 30), (4, 3, 40), (5, 4, 50), (6, 4, 60), (7, 4, 70);

-- No ORDER BY: every row sees the whole table.
SELECT id, sum(v) OVER (), count(*) OVER (), max(v) OVER () FROM df ORDER BY id;

-- ORDER BY with ties: peers share the same running total.
SELECT id, k, sum(v) OVER (ORDER BY k), count(*) OVER (ORDER BY k) FROM df ORDER BY id;

-- The explicit spelling of the default frame gives the same results.
SELECT id, sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM df ORDER BY id;
SELECT id, sum(v) OVER (ORDER BY k RANGE UNBOUNDED PRECEDING) FROM df ORDER BY id;

-- ROWS UNBOUNDED PRECEDING differs from the default when there are ties
-- (keys made unique here so the result is deterministic).
SELECT id, sum(v) OVER (ORDER BY k, id ROWS UNBOUNDED PRECEDING), sum(v) OVER (ORDER BY k) FROM df ORDER BY id;

-- last_value with the default frame returns the last peer, not the last row.
SELECT id, last_value(k) OVER (ORDER BY k), last_value(v) OVER (ORDER BY k, v) FROM df ORDER BY id;

-- With unique ORDER BY keys the default frame equals ROWS UNBOUNDED PRECEDING.
SELECT id, sum(v) OVER (ORDER BY id), sum(v) OVER (ORDER BY id ROWS UNBOUNDED PRECEDING) FROM df ORDER BY id;

-- PARTITION BY without ORDER BY: whole partition.
SELECT id, k, sum(v) OVER (PARTITION BY k), avg(v) OVER (PARTITION BY k) FROM df ORDER BY id;

-- PARTITION BY and ORDER BY on the same column: all rows are peers inside
-- each partition, so every row sees its whole partition.
SELECT id, k, sum(v) OVER (PARTITION BY k ORDER BY k) FROM df ORDER BY id;

-- Descending ORDER BY: peers first, frame grows from the highest key.
SELECT id, k, sum(v) OVER (ORDER BY k DESC) FROM df ORDER BY id;

-- A constant ORDER BY expression makes all rows peers.
SELECT id, sum(v) OVER (ORDER BY 'const') FROM df ORDER BY id;

-- Ordering by an expression with ties (k / 2).
SELECT id, k / 2, sum(v) OVER (ORDER BY k / 2) FROM df ORDER BY id;

-- RANGE CURRENT ROW (start = end = current peer group).
SELECT id, sum(v) OVER (ORDER BY k RANGE CURRENT ROW), sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND CURRENT ROW) FROM df ORDER BY id;
