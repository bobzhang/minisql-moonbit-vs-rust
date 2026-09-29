-- Recursive CTEs generating calendar data with the M4 date functions:
-- day and month series, gap filling with a LEFT JOIN, per-weekday counts.
CREATE TABLE orders(id INTEGER PRIMARY KEY, day TEXT, amount INTEGER);
INSERT INTO orders VALUES (1, '2024-02-27', 10), (2, '2024-02-27', 5), (3, '2024-02-29', 7),
  (4, '2024-03-02', 3), (5, '2024-03-05', 8);

-- Every day from 2024-02-26 to 2024-03-05 (leap year).
WITH RECURSIVE d(day) AS (SELECT '2024-02-26' UNION ALL SELECT date(day, '+1 day') FROM d WHERE day < '2024-03-05')
SELECT day FROM d ORDER BY day;

-- Daily totals with gaps filled by 0.
WITH RECURSIVE d(day) AS (SELECT '2024-02-26' UNION ALL SELECT date(day, '+1 day') FROM d WHERE day < '2024-03-05')
SELECT d.day, coalesce(sum(o.amount), 0) FROM d LEFT JOIN orders o ON o.day = d.day GROUP BY d.day ORDER BY d.day;

-- First day of each month of 2023 and its weekday number.
WITH RECURSIVE m(start) AS (SELECT '2023-01-01' UNION ALL SELECT date(start, '+1 month') FROM m WHERE start < '2023-12-01')
SELECT start, strftime('%w', start) FROM m ORDER BY start;

-- Number of days in each month of 2024.
WITH RECURSIVE m(start) AS (SELECT '2024-01-01' UNION ALL SELECT date(start, '+1 month') FROM m WHERE start < '2024-12-01')
SELECT strftime('%m', start), CAST(julianday(start, '+1 month') - julianday(start) AS INTEGER) FROM m ORDER BY start;

-- How many Fridays (weekday 5) are in 2024?
WITH RECURSIVE d(day) AS (SELECT '2024-01-01' UNION ALL SELECT date(day, '+1 day') FROM d WHERE day < '2024-12-31')
SELECT count(*), sum(strftime('%w', day) = '5') FROM d;

-- Every Monday in March 2024 using the 'weekday' modifier.
WITH RECURSIVE mon(day) AS (SELECT date('2024-03-01', 'weekday 1') UNION ALL
  SELECT date(day, '+7 days') FROM mon WHERE date(day, '+7 days') < '2024-04-01')
SELECT day FROM mon ORDER BY day;

-- Hourly timestamps across a day boundary.
WITH RECURSIVE h(ts) AS (SELECT '2024-12-31 21:00:00' UNION ALL SELECT datetime(ts, '+90 minutes') FROM h WHERE ts < '2025-01-01 03:00:00')
SELECT ts FROM h ORDER BY ts;

-- Month ends via 'start of month', '+1 month', '-1 day'.
WITH RECURSIVE m(k, d) AS (SELECT 1, '2023-11-15' UNION ALL SELECT k + 1, date(d, '+1 month') FROM m WHERE k < 4)
SELECT d, date(d, 'start of month', '+1 month', '-1 day') FROM m ORDER BY k;

-- Unix-epoch seconds stepping by one week.
WITH RECURSIVE w(t) AS (SELECT unixepoch('2024-01-01') UNION ALL SELECT t + 7 * 86400 FROM w WHERE t < unixepoch('2024-02-01'))
SELECT t, date(t, 'unixepoch') FROM w ORDER BY t;

-- Days between the first and last order, counted by recursion vs. julianday.
WITH RECURSIVE d(day, n) AS (SELECT (SELECT min(day) FROM orders), 0 UNION ALL
  SELECT date(day, '+1 day'), n + 1 FROM d WHERE day < (SELECT max(day) FROM orders))
SELECT max(n), julianday('2024-03-05') - julianday('2024-02-27') FROM d;
