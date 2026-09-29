-- date(timevalue, ...) returns 'YYYY-MM-DD'. Time-of-day in the input is
-- dropped. NULL or unparseable input gives NULL.
SELECT date('2024-03-15');
SELECT date('2024-03-15 13:45:30');
SELECT date('2024-03-15T23:59:59');
SELECT date('2024-03-15 13:45'), date('2024-03-15 13:45:30.123');
SELECT date('1970-01-01'), date('2000-02-29'), date('9999-12-31'), date('0000-01-01');

-- Time-only input uses the date 2000-01-01.
SELECT date('13:45'), date('13:45:30');

-- Julian day numbers (numeric arguments).
SELECT date(2460384.5), date(2451544.5), date(2440587.5);
SELECT date(0), date(2460384.9);
-- A numeric string is also a Julian day number.
SELECT date('2440587.5');

-- Leap years.
SELECT date('2024-02-29'), date('2023-02-28'), date('2000-02-29');

-- Invalid inputs.
SELECT date('2024-13-01'), date('2024-3-5'), date('24-03-05'), date('2024/03/05'), date('hello'), date('');
SELECT date(NULL), typeof(date(NULL));

-- The result is TEXT.
SELECT typeof(date('2024-03-15'));

-- Applied to table columns.
CREATE TABLE ev(id INTEGER, ts TEXT);
INSERT INTO ev VALUES (1, '2024-03-15 08:00:00'), (2, '2024-03-15T21:30:00'), (3, '2024-03-16 00:00:00'), (4, 'not a date'), (5, NULL);
SELECT id, date(ts) FROM ev ORDER BY id;
SELECT date(ts), count(*) FROM ev GROUP BY date(ts) ORDER BY 1;
SELECT id FROM ev WHERE date(ts) = '2024-03-15' ORDER BY id;
