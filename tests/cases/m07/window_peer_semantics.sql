-- How each window function treats peers (rows with equal ORDER BY values).
-- Peer-aware results (rank, dense_rank, percent_rank, cume_dist, aggregates
-- with the default RANGE frame, RANGE/GROUPS frames) are identical for all
-- peers. Results that depend on the order among peers (row_number, ntile,
-- lag/lead, ROWS frames) are only checked in aggregate form here.
CREATE TABLE ps(id INTEGER PRIMARY KEY, k INTEGER, v INTEGER);
INSERT INTO ps VALUES (1, 1, 1), (2, 1, 2), (3, 1, 4), (4, 2, 8), (5, 3, 16), (6, 3, 32);

-- Peer-aware functions give equal values to peers.
SELECT id, k, rank() OVER w, dense_rank() OVER w, percent_rank() OVER w, cume_dist() OVER w FROM ps WINDOW w AS (ORDER BY k) ORDER BY id;
SELECT id, k, sum(v) OVER w, count(*) OVER w, max(v) OVER w, min(v) OVER w, avg(v) OVER w FROM ps WINDOW w AS (ORDER BY k) ORDER BY id;
SELECT id, k, sum(v) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING), sum(v) OVER (ORDER BY k GROUPS 1 PRECEDING) FROM ps ORDER BY id;

-- Peer-order-dependent functions: within a peer group the values are a
-- permutation, so per-group aggregates are deterministic.
SELECT k, count(*), sum(rn), min(rn), max(rn) FROM (SELECT k, row_number() OVER (ORDER BY k) AS rn FROM ps) GROUP BY k ORDER BY k;
SELECT k, group_concat(b, ',' ORDER BY b) FROM (SELECT k, ntile(2) OVER (ORDER BY k) AS b FROM ps) GROUP BY k ORDER BY k;

-- lag within the first peer group is NULL for exactly one row.
SELECT sum(p IS NULL), count(*) FROM (SELECT lag(v) OVER (ORDER BY k) AS p FROM ps);

-- A ROWS frame over peers: the sum of a whole-group ROWS frame (via
-- partitioning by the key) is order independent.
SELECT id, sum(v) OVER (PARTITION BY k ORDER BY k ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) FROM ps ORDER BY id;

-- first_value/last_value/nth_value over RANGE frames of peers, applied to
-- the key (equal for all peers).
SELECT id, first_value(k) OVER (ORDER BY k RANGE CURRENT ROW), last_value(k) OVER (ORDER BY k RANGE BETWEEN CURRENT ROW AND 1 FOLLOWING),
  nth_value(k, 4) OVER (ORDER BY k) FROM ps ORDER BY id;

-- Peers under DESC ordering.
SELECT id, rank() OVER (ORDER BY k DESC), sum(v) OVER (ORDER BY k DESC), cume_dist() OVER (ORDER BY k DESC) FROM ps ORDER BY id;

-- Peers determined by an expression (k > 1): two groups.
SELECT id, rank() OVER (ORDER BY k > 1), sum(v) OVER (ORDER BY k > 1), count(*) OVER (ORDER BY k > 1 GROUPS CURRENT ROW) FROM ps ORDER BY id;

-- Adding a tiebreaker turns peers into distinct positions.
SELECT id, rank() OVER (ORDER BY k), rank() OVER (ORDER BY k, id), sum(v) OVER (ORDER BY k, id) FROM ps ORDER BY id;
