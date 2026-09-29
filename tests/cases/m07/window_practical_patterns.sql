-- Common analytics patterns built from window functions: gaps and islands,
-- sessionization, moving averages, percent of total, and change detection.
CREATE TABLE ev(id INTEGER PRIMARY KEY, usr TEXT, ts INTEGER, status TEXT);
INSERT INTO ev VALUES
  (1, 'u1', 100, 'ok'), (2, 'u1', 105, 'ok'), (3, 'u1', 200, 'fail'), (4, 'u1', 210, 'fail'),
  (5, 'u1', 211, 'ok'), (6, 'u2', 50, 'fail'), (7, 'u2', 52, 'ok'), (8, 'u2', 500, 'ok'), (9, 'u2', 505, 'ok');

-- Sessionization: a new session starts after a gap of more than 30.
SELECT usr, ts, sum(new_session) OVER (PARTITION BY usr ORDER BY ts) AS session FROM (
  SELECT usr, ts, CASE WHEN ts - lag(ts) OVER (PARTITION BY usr ORDER BY ts) <= 30 THEN 0 ELSE 1 END AS new_session FROM ev)
ORDER BY usr, ts;

-- Gaps and islands: runs of the same status per user (row_number difference).
SELECT usr, status, min(ts), max(ts), count(*) FROM (
  SELECT usr, ts, status, row_number() OVER (PARTITION BY usr ORDER BY ts) - row_number() OVER (PARTITION BY usr, status ORDER BY ts) AS grp FROM ev)
GROUP BY usr, status, grp ORDER BY usr, min(ts);

-- Status changes: rows whose status differs from the previous row.
SELECT usr, ts, lag(status) OVER (PARTITION BY usr ORDER BY ts), status FROM ev
ORDER BY usr, ts;
SELECT usr, ts FROM (SELECT usr, ts, status, lag(status) OVER (PARTITION BY usr ORDER BY ts) AS prev FROM ev)
WHERE prev IS NOT status ORDER BY usr, ts;

-- Consecutive integers: islands in a set of numbers.
CREATE TABLE nums(n INTEGER PRIMARY KEY);
INSERT INTO nums VALUES (1), (2), (3), (5), (6), (9), (11), (12), (13), (14);
SELECT min(n), max(n), count(*) FROM (SELECT n, n - row_number() OVER (ORDER BY n) AS grp FROM nums) GROUP BY grp ORDER BY min(n);

-- 3-point moving average and cumulative average.
CREATE TABLE daily(d INTEGER PRIMARY KEY, amount INTEGER);
INSERT INTO daily VALUES (1, 10), (2, 20), (3, 60), (4, 10), (5, 50), (6, 30);
SELECT d, amount, avg(amount) OVER (ORDER BY d ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), avg(amount) OVER (ORDER BY d) FROM daily ORDER BY d;

-- Percent of total and cumulative percent.
SELECT d, round(100.0 * amount / sum(amount) OVER (), 2), round(100.0 * sum(amount) OVER (ORDER BY d) / sum(amount) OVER (), 2) FROM daily ORDER BY d;

-- Running maximum and drawdown from the running max.
SELECT d, amount, max(amount) OVER (ORDER BY d), max(amount) OVER (ORDER BY d) - amount FROM daily ORDER BY d;

-- Median via row_number and count (even count averages the two middle values).
SELECT avg(amount) FROM (SELECT amount, row_number() OVER (ORDER BY amount, d) AS rn, count(*) OVER () AS c FROM daily)
WHERE rn IN ((c + 1) / 2, (c + 2) / 2);

-- Year-over-year style comparison with lag over a partition.
CREATE TABLE rev(yr INTEGER, region TEXT, amt INTEGER, PRIMARY KEY (yr, region));
INSERT INTO rev VALUES (2021, 'n', 100), (2022, 'n', 120), (2023, 'n', 90), (2021, 's', 50), (2022, 's', 75), (2023, 's', 75);
SELECT region, yr, amt, amt - lag(amt) OVER (PARTITION BY region ORDER BY yr),
  round(100.0 * (amt - lag(amt) OVER (PARTITION BY region ORDER BY yr)) / lag(amt) OVER (PARTITION BY region ORDER BY yr), 1)
FROM rev ORDER BY region, yr;

-- First and last event per user on every row.
SELECT DISTINCT usr, first_value(ts) OVER w, last_value(ts) OVER w FROM ev
WINDOW w AS (PARTITION BY usr ORDER BY ts ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) ORDER BY usr;
