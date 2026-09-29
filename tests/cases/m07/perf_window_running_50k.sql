-- @timeout 5
-- Performance: window functions over a single 50k-row partition. Running
-- aggregates must be computed incrementally (recomputing each frame from
-- scratch is quadratic), and sliding / RANGE / GROUPS frames must find
-- their bounds without rescanning the partition for every row.
CREATE TABLE s(id INTEGER PRIMARY KEY, v INTEGER, k INTEGER);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 50000)
INSERT INTO s SELECT x, (x * 7919) % 1009, x / 7 FROM c;

-- Running sum over the whole table (default frame).
SELECT count(*), sum(rs), max(rs) FROM (SELECT sum(v) OVER (ORDER BY id) AS rs FROM s);
-- Running count with peers (7 rows per k value).
SELECT sum(rc) FROM (SELECT count(*) OVER (ORDER BY k) AS rc FROM s);

-- Sliding sum and sliding max.
SELECT sum(ms) FROM (SELECT sum(v) OVER (ORDER BY id ROWS BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS ms FROM s);
SELECT sum(mx) FROM (SELECT max(v) OVER (ORDER BY id ROWS 50 PRECEDING) AS mx FROM s);

-- Ranking over the whole table.
SELECT sum(rn), sum(nt) FROM (SELECT row_number() OVER (ORDER BY v, id) AS rn, ntile(100) OVER (ORDER BY v, id) AS nt FROM s);

-- RANGE and GROUPS frames.
SELECT sum(c) FROM (SELECT count(*) OVER (ORDER BY v RANGE BETWEEN 5 PRECEDING AND 5 FOLLOWING) AS c FROM s);
SELECT sum(g) FROM (SELECT sum(v) OVER (ORDER BY k GROUPS BETWEEN 2 PRECEDING AND 1 FOLLOWING) AS g FROM s);

-- lag with an offset and default.
SELECT count(*), sum(d) FROM (SELECT v - lag(v, 3, 0) OVER (ORDER BY id) AS d FROM s);
