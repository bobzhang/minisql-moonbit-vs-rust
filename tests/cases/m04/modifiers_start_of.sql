-- 'start of day', 'start of month', 'start of year' move back to the
-- beginning of the unit (time becomes 00:00:00).
SELECT datetime('2024-03-15 13:45:30', 'start of day');
SELECT datetime('2024-03-15 13:45:30', 'start of month');
SELECT datetime('2024-03-15 13:45:30', 'start of year');
SELECT date('2024-01-01', 'start of month'), date('2024-12-31', 'start of year'), date('2024-02-29', 'start of month');
-- Fractional seconds are cleared too.
SELECT datetime('2024-03-15 13:14:15.678', 'start of day', 'subsec');
-- Applied to a time-only value (date 2000-01-01).
SELECT datetime('13:14:15', 'start of day'), datetime('13:14', 'start of year');

-- Common patterns.
-- Last day of the month.
SELECT date('2024-02-10', 'start of month', '+1 month', '-1 day'), date('2023-02-10', 'start of month', '+1 month', '-1 day');
-- First day of next month.
SELECT date('2024-12-20', 'start of month', '+1 month');
-- Last second of the year.
SELECT datetime('2024-06-01', 'start of year', '+1 year', '-1 second');
-- Day of year arithmetic.
SELECT date('2024-03-15', 'start of year', '+59 days');
-- Several start-of modifiers in a row.
SELECT date('2024-08-19', 'start of month', 'start of year');

-- Start of day on a Julian day number and a unix timestamp.
SELECT datetime(2460384.9, 'start of day'), datetime(1710500000, 'unixepoch', 'start of day');

-- Misspelled forms give NULL.
SELECT date('2024-03-15', 'start of week'), date('2024-03-15', 'start month'), date('2024-03-15', 'startofmonth');

-- Grouping by month start.
CREATE TABLE s(ts TEXT, amt INTEGER);
INSERT INTO s VALUES ('2024-01-03 10:00', 5), ('2024-01-28 11:00', 1), ('2024-02-14 09:00', 7), ('2024-02-29 23:59', 2), ('2025-01-01 00:00', 9);
SELECT date(ts, 'start of month') AS m, sum(amt) FROM s GROUP BY m ORDER BY m;
SELECT date(ts, 'start of year') AS y, count(*) FROM s GROUP BY y ORDER BY y;
