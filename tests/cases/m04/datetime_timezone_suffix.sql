-- A time value may end with a time-zone indicator: 'Z' or [+-]HH:MM. The
-- result is converted to UTC by subtracting the offset.
SELECT datetime('2024-03-15 12:00:00Z'), datetime('2024-03-15 12:00:00z');
SELECT datetime('2024-03-15 12:00:00+02:00'), datetime('2024-03-15 12:00:00-05:00');
SELECT datetime('2024-03-15 12:00+05:30'), datetime('2024-03-15T12:00:00.25-00:30');
-- Crossing a day boundary.
SELECT datetime('2024-03-15 01:00:00+03:00'), datetime('2024-03-15 22:00:00-04:00');
SELECT datetime('2024-01-01 00:30:00+01:00'), date('2024-12-31 23:00:00-02:00');
-- A space before the offset is allowed.
SELECT datetime('2024-03-15 12:00:00 +01:00');
-- Offsets on time-only values.
SELECT time('08:00+08:00'), time('20:00-06:00');
-- julianday and unixepoch see the UTC instant.
SELECT unixepoch('2024-03-15 12:00:00+02:00') = unixepoch('2024-03-15 10:00:00');
SELECT julianday('2024-03-15 12:00:00+06:00');

-- Offsets that are not accepted.
SELECT datetime('2024-03-15 12:00:00+0200'), datetime('2024-03-15 12:00:00+2:00'), datetime('2024-03-15 12:00:00 UTC');

-- strftime also normalizes to UTC.
SELECT strftime('%Y-%m-%d %H:%M', '2024-03-15 00:15-00:30');
SELECT strftime('%H:%M:%S', '2024-03-15 23:45:00+00:00');
