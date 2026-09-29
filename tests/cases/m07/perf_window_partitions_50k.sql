-- @timeout 5
-- Performance: window functions over 50k rows split into 200 partitions:
-- ranking, running sums, lag, top-N per partition and value-range frames.
-- Requires sorting by (partition, order) once per window, not per row.
CREATE TABLE s(id INTEGER PRIMARY KEY, g INTEGER, v INTEGER);
WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 50000)
INSERT INTO s SELECT x, (x * 31) % 200, (x * 7919) % 1009 FROM c;

-- Ranking functions per partition, summarized.
SELECT sum(rn), sum(rk), max(rn) FROM (SELECT row_number() OVER (PARTITION BY g ORDER BY id) AS rn,
  rank() OVER (PARTITION BY g ORDER BY v) AS rk FROM s);

-- Running sums per partition (only a few partitions reported).
SELECT g, max(rs), count(*) FROM (SELECT g, sum(v) OVER (PARTITION BY g ORDER BY id) AS rs FROM s) WHERE g IN (0, 7, 199) GROUP BY g ORDER BY g;

-- lag per partition.
SELECT count(d), sum(d) FROM (SELECT v - lag(v) OVER (PARTITION BY g ORDER BY id) AS d FROM s);

-- Top 3 per partition.
SELECT count(*), sum(v) FROM (SELECT v, row_number() OVER (PARTITION BY g ORDER BY v DESC, id) AS rn FROM s) WHERE rn <= 3;

-- Value-range frame inside partitions.
SELECT sum(b) FROM (SELECT count(*) OVER (PARTITION BY g ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING) AS b FROM s);

-- Window over grouped data.
SELECT sum(r) FROM (SELECT rank() OVER (ORDER BY sum(v) DESC, g) AS r FROM s GROUP BY g);
