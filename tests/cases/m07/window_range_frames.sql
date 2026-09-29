-- RANGE frames: bounds are based on the ORDER BY value, not row counts.
-- "N PRECEDING" means ORDER BY value >= current value - N (ascending).
-- CURRENT ROW in RANGE mode means the first/last peer of the current row.
CREATE TABLE rg(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO rg VALUES (1, 1, 1), (2, 2, 2), (3, 2, 4), (4, 4, 8), (5, 5, 16), (6, 5, 32), (7, 9, 64), (8, 10, 128);

-- Value-based windows: within 1 of the current value.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM rg ORDER BY id;

-- Only preceding values within 2, including peers.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE 2 PRECEDING) FROM rg ORDER BY id;

-- Following values within 3.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND 3 FOLLOWING) FROM rg ORDER BY id;

-- CURRENT ROW as start and end: the peer group only.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND CURRENT ROW) FROM rg ORDER BY id;

-- CURRENT ROW to UNBOUNDED FOLLOWING includes earlier peers too.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) FROM rg ORDER BY id;

-- Frames entirely before / after the current value.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN 3 PRECEDING AND 1 PRECEDING),
  sum(v) OVER (ORDER BY k RANGE BETWEEN 1 FOLLOWING AND 4 FOLLOWING) FROM rg ORDER BY id;

-- 0 PRECEDING and 0 FOLLOWING equal CURRENT ROW (the peers).
SELECT id, count(*) OVER (ORDER BY k RANGE BETWEEN 0 PRECEDING AND 0 FOLLOWING) FROM rg ORDER BY id;

-- UNBOUNDED on both sides.
SELECT DISTINCT sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM rg;

-- UNBOUNDED PRECEDING to N PRECEDING / N FOLLOWING.
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND 2 PRECEDING),
  sum(v) OVER (ORDER BY k RANGE BETWEEN UNBOUNDED PRECEDING AND 1 FOLLOWING) FROM rg ORDER BY id;

-- RANGE with an ORDER BY expression.
SELECT id, k * 10, sum(v) OVER (ORDER BY k * 10 RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) FROM rg ORDER BY id;

-- Per partition.
SELECT id, k % 2, k, sum(v) OVER (PARTITION BY k % 2 ORDER BY k RANGE 4 PRECEDING) FROM rg ORDER BY id;

-- Counting neighbours within a distance (a typical RANGE use).
SELECT id, k, count(*) OVER (ORDER BY k RANGE BETWEEN 5 PRECEDING AND 5 FOLLOWING) - 1 FROM rg ORDER BY id;

-- RANGE CURRENT ROW / UNBOUNDED bounds do not need a single ORDER BY term.
SELECT id, sum(v) OVER (ORDER BY k, id RANGE BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM rg ORDER BY id;

-- Errors: RANGE with an N PRECEDING/FOLLOWING offset needs exactly one ORDER BY term.
SELECT sum(v) OVER (ORDER BY k, id RANGE 1 PRECEDING) FROM rg;
SELECT sum(v) OVER (RANGE BETWEEN 1 PRECEDING AND CURRENT ROW) FROM rg;
