-- datetime() with each accepted input format.
-- YYYY-MM-DD
SELECT datetime('2024-03-15');
-- YYYY-MM-DD HH:MM, HH:MM:SS, HH:MM:SS.SSS (space or T separator)
SELECT datetime('2024-03-15 13:45'), datetime('2024-03-15T13:45');
SELECT datetime('2024-03-15 13:45:30'), datetime('2024-03-15T13:45:30');
SELECT datetime('2024-03-15 13:45:30.123'), datetime('2024-03-15T13:45:30.999');
-- HH:MM, HH:MM:SS, HH:MM:SS.SSS alone (date 2000-01-01)
SELECT datetime('13:45'), datetime('13:45:30'), datetime('13:45:30.5');
-- Julian day number, integer or real
SELECT datetime(2460384.5), datetime(2460385), datetime(2460384.25);
SELECT datetime(2451545.0), datetime(0.0);

-- More fractional digits are accepted.
SELECT datetime('2024-03-15 13:45:30.123456');

-- Numeric text is a Julian day number.
SELECT datetime('2460384.5');

-- Unix timestamps need the 'unixepoch' modifier.
SELECT datetime(1710460800, 'unixepoch'), datetime(0, 'unixepoch');
SELECT datetime(1710460800.5, 'unixepoch');

-- Formats that are not accepted.
SELECT datetime('2024-03-15 1:45'), datetime('2024-03-15 13'), datetime('20240315');
SELECT datetime('2024-3-15'), datetime('March 15, 2024'), datetime('2024-03-15 13:45:30 PM');

-- Boundaries of the supported range.
SELECT datetime('0000-01-01 00:00:00'), datetime('9999-12-31 23:59:59');
SELECT datetime(0), datetime(5373484.4);
SELECT datetime(5373484.5), datetime(-1);

-- Result type and NULL.
SELECT typeof(datetime('2024-03-15')), datetime(NULL);
