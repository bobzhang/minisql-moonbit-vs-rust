-- 'subsec' / 'subsecond' make datetime/time/unixepoch keep milliseconds.
-- 'floor' and 'ceiling' choose how an overflowing day is handled by the
-- preceding month/year modifier: 'ceiling' (the default) rolls over into
-- the next month, 'floor' clamps to the last day of the month.
SELECT datetime('2024-03-15 10:20:30.456', 'subsec'), datetime('2024-03-15 10:20:30.456');
SELECT time('10:20:30.456', 'subsec'), time('10:20:30.456', 'subsecond');
SELECT datetime('2024-03-15 10:20:30', 'subsec'), unixepoch('2024-03-15 10:20:30.456', 'subsec');
SELECT datetime(1710498030.25, 'unixepoch', 'subsec');
SELECT datetime('2024-03-15 12:00:00', '+1.25 seconds', 'subsec');
-- subsec may appear anywhere in the modifier list.
SELECT datetime('2024-03-15 10:20:30.5', 'subsec', '+1 day');
-- date() ignores subsec.
SELECT date('2024-03-15 10:20:30.456', 'subsec');

-- floor / ceiling after month arithmetic.
SELECT date('2024-01-31', '+1 month'), date('2024-01-31', '+1 month', 'ceiling'), date('2024-01-31', '+1 month', 'floor');
SELECT date('2023-01-31', '+1 month', 'floor'), date('2024-03-31', '-1 month', 'floor'), date('2024-05-31', '+1 month', 'floor');
SELECT date('2024-02-29', '+1 year', 'floor'), date('2024-02-29', '+1 year', 'ceiling');
SELECT datetime('2024-01-31 08:00', '+1 month', 'floor');
-- When the day exists, floor and ceiling change nothing.
SELECT date('2024-01-15', '+1 month', 'floor'), date('2024-01-15', '+1 month', 'ceiling');
-- Without a preceding month/year modifier they have no effect.
SELECT date('2024-03-31', 'floor'), datetime('2024-03-15 10:00:00', 'ceiling');

-- Month-end schedule with floor.
CREATE TABLE m(n INTEGER);
INSERT INTO m VALUES (1), (2), (3), (4);
SELECT n, date('2024-01-31', '+' || n || ' months', 'floor'), date('2024-01-31', '+' || n || ' months') FROM m ORDER BY n;
