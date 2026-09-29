-- '+N days', '+N hours', '+N minutes', '+N seconds' (and negatives,
-- fractions, and singular forms).
SELECT date('2024-03-15', '+1 day'), date('2024-03-15', '+10 days'), date('2024-03-15', '-15 days');
SELECT date('2024-12-31', '+1 day'), date('2024-03-01', '-1 day'), date('2023-03-01', '-1 day');
SELECT date('1900-02-28', '+1 day'), date('2000-02-28', '+1 day'), date('2100-02-28', '+1 day');
SELECT datetime('2024-03-15 10:00:00', '+5 hours'), datetime('2024-03-15 10:00:00', '+14 hours'), datetime('2024-03-15 10:00:00', '-11 hours');
SELECT datetime('2024-03-15 10:00:00', '+90 minutes'), datetime('2024-03-15 10:00:00', '-601 minutes');
SELECT datetime('2024-03-15 23:59:59', '+1 second'), datetime('2024-03-15 00:00:00', '-1 second');
SELECT datetime('2024-03-15', '+86400 seconds'), datetime('2024-03-15', '+1440 minutes'), datetime('2024-03-15', '+24 hours');

-- Fractional amounts.
SELECT datetime('2024-03-15 12:00:00', '+0.25 days'), datetime('2024-03-15 12:00:00', '-1.5 days');
SELECT datetime('2024-03-15 12:00:00', '+1.5 hours'), datetime('2024-03-15 12:00:00', '+30.5 minutes');

-- Singular and plural, and upper case, are all accepted; the '+' is optional.
SELECT date('2024-03-15', '+1 days'), date('2024-03-15', '+2 day'), date('2024-03-15', '+1 DAY'), date('2024-03-15', '3 days');
SELECT datetime('2024-03-15', '+1 hour', '+1 minute', '+1 second');

-- Modifiers apply left to right.
SELECT datetime('2024-03-15 22:30', '+1 hour', '+45 minutes', '-2 days');

-- Zero and large amounts.
SELECT date('2024-03-15', '+0 days'), date('2024-03-15', '+1000 days'), date('2024-03-15', '-10000 days');

-- Unknown or malformed modifiers give NULL.
SELECT date('2024-03-15', '+1 fortnight'), date('2024-03-15', '+x days'), date('2024-03-15', 'days');
-- A NULL modifier gives NULL.
SELECT date('2024-03-15', NULL);

-- Modifiers built from column values.
CREATE TABLE t(id INTEGER, start TEXT, dur INTEGER);
INSERT INTO t VALUES (1, '2024-01-30', 3), (2, '2024-02-27', 2), (3, '2024-12-30', 5);
SELECT id, date(start, '+' || dur || ' days') FROM t ORDER BY id;
SELECT id, date(start, '-' || (dur * 10) || ' days') FROM t ORDER BY id;
