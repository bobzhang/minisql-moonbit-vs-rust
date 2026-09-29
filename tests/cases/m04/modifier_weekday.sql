-- 'weekday N' moves forward to the next date whose weekday is N (0 = Sunday
-- ... 6 = Saturday). If the date is already that weekday it is unchanged.
-- 2024-03-15 is a Friday (5).
SELECT date('2024-03-15', 'weekday 0'), date('2024-03-15', 'weekday 1'), date('2024-03-15', 'weekday 4');
SELECT date('2024-03-15', 'weekday 5'), date('2024-03-15', 'weekday 6');
-- The time of day is kept.
SELECT datetime('2024-03-15 10:20:30', 'weekday 5'), datetime('2024-03-15 10:20:30', 'weekday 1');
-- Across a month and year boundary.
SELECT date('2024-12-30', 'weekday 0'), date('2024-02-28', 'weekday 6');

-- Common patterns: previous Monday (start of week) and next Friday.
SELECT date('2024-03-15', '-6 days', 'weekday 1');
SELECT date('2024-03-18', '-6 days', 'weekday 1');
SELECT date('2024-03-15', '+1 day', 'weekday 5');
-- First Monday of a month.
SELECT date('2024-09-17', 'start of month', 'weekday 1');
-- Last Sunday of a month.
SELECT date('2024-03-10', 'start of month', '+1 month', '-7 days', 'weekday 0');

-- Out-of-range or malformed N gives NULL.
SELECT date('2024-03-15', 'weekday 7'), date('2024-03-15', 'weekday -1'), date('2024-03-15', 'weekday');

-- For every day of a week, the following Sunday.
CREATE TABLE d(n INTEGER);
INSERT INTO d VALUES (0), (1), (2), (3), (4), (5), (6);
SELECT date('2024-03-10', '+' || n || ' days') AS day, date('2024-03-10', '+' || n || ' days', 'weekday 0') FROM d ORDER BY n;
SELECT strftime('%w', date('2024-03-10', '+' || n || ' days', 'weekday 3')), count(*) FROM d GROUP BY 1;
