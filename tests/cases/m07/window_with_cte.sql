-- CTEs and window functions together: windows inside CTE bodies, windows
-- over CTE output, and recursive CTEs feeding window queries.
CREATE TABLE readings(id INTEGER PRIMARY KEY, sensor TEXT, t INTEGER, val INTEGER);
INSERT INTO readings VALUES (1, 's1', 1, 10), (2, 's1', 2, 12), (3, 's1', 3, 9), (4, 's1', 4, 15),
  (5, 's2', 1, 100), (6, 's2', 2, 90), (7, 's2', 3, 95);

-- Window inside a CTE, filtered outside.
WITH d AS (SELECT sensor, t, val - lag(val) OVER (PARTITION BY sensor ORDER BY t) AS delta FROM readings)
SELECT sensor, t, delta FROM d WHERE delta < 0 ORDER BY sensor, t;

-- Window over a CTE.
WITH s1 AS (SELECT t, val FROM readings WHERE sensor = 's1')
SELECT t, val, avg(val) OVER (ORDER BY t ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) FROM s1 ORDER BY t;

-- Window over a recursive CTE: a generated series with running statistics.
WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10)
SELECT i, sum(i) OVER (ORDER BY i), sum(i) OVER (ORDER BY i ROWS 2 PRECEDING), ntile(3) OVER (ORDER BY i) FROM n ORDER BY i;

-- Chained CTEs each adding a window step.
WITH a AS (SELECT sensor, t, val, row_number() OVER (PARTITION BY sensor ORDER BY val DESC) AS rk FROM readings),
     b AS (SELECT sensor, t, val, rk, sum(val) OVER (PARTITION BY sensor ORDER BY rk) AS cum FROM a)
SELECT sensor, rk, val, cum FROM b ORDER BY sensor, rk;

-- Recursive CTE results compared with the equivalent window computation.
WITH RECURSIVE run(t, total) AS (
  SELECT t, val FROM readings WHERE sensor = 's1' AND t = 1
  UNION ALL
  SELECT r.t, run.total + r.val FROM run JOIN readings r ON r.sensor = 's1' AND r.t = run.t + 1)
SELECT run.t, run.total, w.total, run.total = w.total FROM run
JOIN (SELECT t, sum(val) OVER (ORDER BY t) AS total FROM readings WHERE sensor = 's1') w ON w.t = run.t ORDER BY run.t;

-- Gaps in a generated calendar filled, then windowed.
WITH RECURSIVE ts(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM ts WHERE t < 5)
SELECT ts.t, r.val, count(r.val) OVER (ORDER BY ts.t) FROM ts LEFT JOIN readings r ON r.t = ts.t AND r.sensor = 's2' ORDER BY ts.t;

-- A window's output used as the anchor of a recursive CTE.
WITH RECURSIVE top(sensor, val, step) AS (
  SELECT sensor, val, 0 FROM (SELECT sensor, val, row_number() OVER (PARTITION BY sensor ORDER BY val DESC) AS rn FROM readings) WHERE rn = 1
  UNION ALL
  SELECT sensor, val / 2, step + 1 FROM top WHERE step < 2)
SELECT sensor, step, val FROM top ORDER BY sensor, step;

-- A CTE with a named window.
WITH w AS (SELECT sensor, t, sum(val) OVER win AS s FROM readings WINDOW win AS (PARTITION BY sensor ORDER BY t ROWS UNBOUNDED PRECEDING))
SELECT sensor, max(s) FROM w GROUP BY sensor ORDER BY sensor;

-- WITH ... INSERT of window results.
CREATE TABLE ranks(sensor TEXT, t INTEGER, rk INTEGER);
WITH r AS (SELECT sensor, t, rank() OVER (PARTITION BY sensor ORDER BY val) AS rk FROM readings)
INSERT INTO ranks SELECT sensor, t, rk FROM r;
SELECT sensor, t, rk FROM ranks ORDER BY sensor, t;
