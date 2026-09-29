-- strftime(format, timevalue, ...): the common substitutions.
SELECT strftime('%Y-%m-%d', '2024-03-05 07:08:09');
SELECT strftime('%H:%M:%S', '2024-03-05 07:08:09');
SELECT strftime('%d/%m/%Y %H.%M', '2024-03-05 07:08:09');
-- %f: seconds with milliseconds.
SELECT strftime('%f', '2024-03-05 07:08:09.25'), strftime('%f', '2024-03-05 07:08:09');
-- %e, %k, %l: space-padded day, 24-hour, 12-hour.
SELECT '[' || strftime('%e', '2024-03-05') || ']', '[' || strftime('%k', '2024-03-05 07:00') || ']', '[' || strftime('%l', '2024-03-05 19:00') || ']';
-- %I, %p, %P: 12-hour clock with AM/PM.
SELECT strftime('%I %p', '2024-03-05 00:30'), strftime('%I %p', '2024-03-05 12:30'), strftime('%I %P', '2024-03-05 13:30');
-- %j: day of year.
SELECT strftime('%j', '2024-01-01'), strftime('%j', '2024-12-31'), strftime('%j', '2023-12-31');
-- %s: unix seconds; %J: Julian day number.
SELECT strftime('%s', '2024-03-05 07:08:09'), strftime('%J', '2024-03-05 18:00');
-- %F = %Y-%m-%d, %T = %H:%M:%S, %R = %H:%M.
SELECT strftime('%F', '2024-03-05 07:08:09'), strftime('%T', '2024-03-05 07:08:09'), strftime('%R', '2024-03-05 07:08:09');
-- %% is a literal percent; other text is copied.
SELECT strftime('100%% on %Y', '2024-03-05'), strftime('year:%Y!', '2024-03-05');
-- Years below 1000 are zero padded.
SELECT strftime('%Y', '0005-06-07');

-- The result is TEXT, even for %s.
SELECT typeof(strftime('%s', '2024-03-05')), typeof(strftime('%Y', '2024-03-05'));

-- NULL format or time value gives NULL; a format without substitutions is
-- returned as is.
SELECT strftime(NULL, '2024-03-05'), strftime('%Y', NULL), strftime('plain', '2024-03-05');
-- An invalid time value gives NULL.
SELECT strftime('%Y', 'garbage');

-- With modifiers.
SELECT strftime('%Y-%m-%d %H:%M', '2024-03-05 07:08', '+1 day', '+2 hours');

-- Grouping by a formatted value.
CREATE TABLE o(id INTEGER, ts TEXT, amt INTEGER);
INSERT INTO o VALUES (1, '2024-01-15 10:00', 5), (2, '2024-01-20 11:00', 7), (3, '2024-02-01 09:00', 3), (4, '2024-03-10 12:00', 4), (5, '2024-03-11 08:00', 6);
SELECT strftime('%Y-%m', ts) AS month, sum(amt) FROM o GROUP BY month ORDER BY month;
SELECT strftime('%H', ts) AS hour, count(*) FROM o GROUP BY hour ORDER BY hour;
