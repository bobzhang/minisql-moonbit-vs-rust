-- Date/time functions combined with GROUP BY and aggregates.
CREATE TABLE visits(id INTEGER PRIMARY KEY, at TEXT, secs INTEGER);
INSERT INTO visits(at, secs) VALUES
  ('2024-01-01 08:15:00', 30), ('2024-01-01 21:40:10', 45), ('2024-01-02 09:00:00', 10),
  ('2024-01-07 12:00:00', 60), ('2024-01-08 07:30:00', 20), ('2024-02-01 00:00:00', 5),
  ('2024-02-29 23:59:59', 15), ('2024-03-03 10:10:10', 25);

-- Per day.
SELECT date(at) AS d, count(*), sum(secs) FROM visits GROUP BY d ORDER BY d;
-- Per month.
SELECT strftime('%Y-%m', at) AS m, count(*), avg(secs) FROM visits GROUP BY m ORDER BY m;
-- Per weekday (0 = Sunday).
SELECT strftime('%w', at) AS dow, count(*) FROM visits GROUP BY dow ORDER BY dow;
-- Per ISO week.
SELECT strftime('%G-W%V', at) AS wk, count(*) FROM visits GROUP BY wk ORDER BY wk;
-- Per start-of-week (Monday).
SELECT date(at, '-6 days', 'weekday 1') AS wk, count(*) FROM visits GROUP BY wk ORDER BY wk;
-- Morning vs evening.
SELECT CAST(strftime('%H', at) AS INTEGER) < 12 AS morning, count(*) FROM visits GROUP BY morning ORDER BY morning;

-- First and last visit, and the span in days.
SELECT min(at), max(at) FROM visits;
SELECT round(julianday(max(at)) - julianday(min(at)), 3) FROM visits;
-- The bare-column rule with a date extremum.
SELECT id, max(at) FROM visits;
SELECT date(at), min(secs) FROM visits;

-- Total seconds, expressed as a time.
SELECT sum(secs), time(sum(secs), 'unixepoch') FROM visits;
-- Latest visit per month.
SELECT strftime('%m', at) AS m, max(time(at)) FROM visits GROUP BY m ORDER BY m;
-- HAVING on a date expression.
SELECT date(at, 'start of month') AS m FROM visits GROUP BY m HAVING count(*) > 1 ORDER BY m;
-- Visits within 7 days of the first one.
SELECT count(*) FROM visits WHERE julianday(at) - julianday('2024-01-01 08:15:00') < 7;
