-- Weekday and week-number substitutions:
--   %w  day of week 0-6, Sunday = 0      %u  day of week 1-7, Monday = 1
--   %W  week of year 00-53, weeks start Monday (days before the first
--       Monday are week 00)
--   %U  week of year 00-53, weeks start Sunday
--   %V  ISO 8601 week number 01-53       %G  ISO 8601 year  %g  its last 2 digits
SELECT strftime('%w %u', '2024-03-17'), strftime('%w %u', '2024-03-18'), strftime('%w %u', '2024-03-23');
SELECT strftime('%W %U %V %G %g', '2024-01-01');
SELECT strftime('%W %U %V %G %g', '2023-01-01');
SELECT strftime('%W %U %V %G %g', '2021-01-03');
SELECT strftime('%W %U %V %G %g', '2020-12-31');
SELECT strftime('%W %U %V %G %g', '2024-12-30');
SELECT strftime('%W %U %V %G %g', '2026-06-15');
SELECT strftime('%W %U %V %G %g', '2015-12-31');
SELECT strftime('%W %U %V %G %g', '2016-01-01');

-- Every day of one week.
CREATE TABLE d(n INTEGER);
INSERT INTO d VALUES (0), (1), (2), (3), (4), (5), (6);
SELECT date('2024-03-17', '+' || n || ' days') AS day, strftime('%w', '2024-03-17', '+' || n || ' days'), strftime('%u', '2024-03-17', '+' || n || ' days')
FROM d ORDER BY n;

-- Count days per weekday in a range.
CREATE TABLE r(day TEXT);
INSERT INTO r SELECT date('2024-02-01', '+' || n || ' days') FROM d;
INSERT INTO r SELECT date('2024-02-08', '+' || n || ' days') FROM d WHERE n < 3;
SELECT strftime('%w', day) AS dow, count(*) FROM r GROUP BY dow ORDER BY dow;
SELECT strftime('%V', day) AS wk, min(day), max(day) FROM r GROUP BY wk ORDER BY wk;
