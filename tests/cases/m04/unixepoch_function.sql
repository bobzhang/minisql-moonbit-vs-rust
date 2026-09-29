-- unixepoch() returns seconds since 1970-01-01 00:00:00 UTC as an INTEGER
-- (fractional seconds truncated), or a REAL with 'subsec'.
SELECT unixepoch('1970-01-01'), unixepoch('1970-01-02'), unixepoch('2024-03-15');
SELECT unixepoch('2024-03-15 12:34:56'), unixepoch('2000-01-01T00:00:00Z');
SELECT unixepoch('1969-12-31 23:59:59'), unixepoch('1900-01-01');
SELECT typeof(unixepoch('2024-03-15')), unixepoch('2024-03-15 00:00:00.999');
-- Beyond 32 bits.
SELECT unixepoch('2038-01-19 03:14:08'), unixepoch('9999-12-31 23:59:59');

-- 'subsec' keeps the fraction and returns a REAL.
SELECT unixepoch('2024-03-15 00:00:00.250', 'subsec'), typeof(unixepoch('2024-03-15', 'subsec'));
SELECT unixepoch('2024-03-15 00:00:00.5', 'subsecond');

-- From a Julian day number.
SELECT unixepoch(2440587.5), unixepoch(2440588.0);
-- From a unix timestamp (identity) and with modifiers.
SELECT unixepoch(1710460800, 'unixepoch'), unixepoch(1710460800, 'unixepoch', '+1 day');
SELECT unixepoch('2024-03-15', '+1 hour') - unixepoch('2024-03-15');

-- strftime('%s') gives the same number as text.
SELECT strftime('%s', '2024-03-15 12:34:56'), typeof(strftime('%s', '2024-03-15'));

-- Differences in seconds.
SELECT unixepoch('2024-03-15 10:00:00') - unixepoch('2024-03-15 08:30:00');

-- Invalid and NULL input.
SELECT unixepoch('bogus'), unixepoch(NULL);

-- Round trip.
SELECT datetime(unixepoch('2024-03-15 12:34:56'), 'unixepoch');

-- On a table.
CREATE TABLE t(id INTEGER, ts TEXT);
INSERT INTO t VALUES (1, '2024-01-01 00:00:00'), (2, '2024-01-01 00:01:40'), (3, '2024-01-01 01:00:00');
SELECT id, unixepoch(ts) - unixepoch('2024-01-01') FROM t ORDER BY id;
SELECT sum(unixepoch(ts) - unixepoch('2024-01-01')) FROM t;
