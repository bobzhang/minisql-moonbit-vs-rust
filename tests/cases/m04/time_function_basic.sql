-- time(timevalue, ...) returns 'HH:MM:SS' (fractional seconds dropped unless
-- 'subsec' is used).
SELECT time('13:45'), time('13:45:30'), time('13:45:30.999');
SELECT time('2024-03-15 06:07:08'), time('2024-03-15T23:59:59'), time('2024-03-15');
SELECT time('00:00'), time('23:59:59'), time('12:00:00.5');

-- Julian day fractions.
SELECT time(2460384.5), time(2460384.75), time(2460385.0), time(2460384.625);

-- With a time zone suffix, the time is converted to UTC.
SELECT time('10:00:00Z'), time('10:00:00+02:00'), time('10:00:00-03:30');
SELECT time('2024-03-15 01:00:00+05:00');

-- Invalid times.
SELECT time('25:00:00'), time('12:60'), time('12:30:60'), time('1:30'), time('noon');
SELECT time(NULL);

-- time() with modifiers.
SELECT time('10:00', '+90 minutes'), time('23:30', '+1 hour'), time('00:15', '-30 minutes');
SELECT time('10:20:30', 'start of day');

-- time() on a column.
CREATE TABLE s(id INTEGER, at TEXT);
INSERT INTO s VALUES (1, '2024-01-01 09:15:00'), (2, '2024-01-02 17:45:30'), (3, '08:00');
SELECT id, time(at), time(at, '+15 minutes') FROM s ORDER BY id;
SELECT id FROM s WHERE time(at) < '12:00:00' ORDER BY id;
