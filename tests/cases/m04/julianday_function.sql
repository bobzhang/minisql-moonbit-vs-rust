-- julianday() returns the Julian day number as a REAL: days since noon in
-- Greenwich on November 24, 4714 B.C. (proleptic Gregorian).
SELECT julianday('2000-01-01 12:00:00'), julianday('2000-01-01');
SELECT julianday('2024-03-15'), julianday('2024-03-15 06:00:00'), julianday('2024-03-15 18:00');
SELECT julianday('1970-01-01'), julianday('-4713-11-24 12:00:00');
SELECT typeof(julianday('2024-03-15'));

-- A number is already a Julian day number.
SELECT julianday(2460384.5), julianday(0), julianday('2460384.5');
-- Unix timestamps with 'unixepoch'.
SELECT julianday(0, 'unixepoch'), julianday(86400, 'unixepoch');

-- Differences between Julian days are day counts.
SELECT julianday('2024-03-15') - julianday('2024-01-01');
SELECT julianday('2025-01-01') - julianday('2024-01-01'), julianday('2024-01-01') - julianday('2023-01-01');
SELECT (julianday('2024-03-15 18:00') - julianday('2024-03-15 06:00')) * 24;
SELECT CAST(julianday('2024-12-25') - julianday('2024-03-15') AS INTEGER);

-- With modifiers.
SELECT julianday('2024-03-15', '+1 day') - julianday('2024-03-15');
SELECT julianday('2024-03-15', 'start of year');

-- Round trip through date/datetime.
SELECT date(julianday('2024-03-15')), datetime(julianday('2024-03-15 12:34:56'));

-- Invalid and NULL.
SELECT julianday('nope'), julianday(NULL), julianday('2024-02-30x');

-- On a table: day gaps between consecutive events (ordered).
CREATE TABLE e(id INTEGER, d TEXT);
INSERT INTO e VALUES (1, '2024-01-01'), (2, '2024-01-31'), (3, '2024-03-01'), (4, '2024-12-31');
SELECT id, julianday(d) - julianday('2024-01-01') FROM e ORDER BY id;
SELECT max(julianday(d)) - min(julianday(d)) FROM e;
