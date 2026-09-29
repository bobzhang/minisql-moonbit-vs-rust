-- timediff(A, B) returns the time from B to A as text of the form
-- '(+|-)YYYY-MM-DD HH:MM:SS.SSS', using calendar arithmetic.
SELECT timediff('2024-03-15', '2024-01-01');
SELECT timediff('2024-01-01', '2024-03-15');
SELECT timediff('2024-03-15 12:30:00', '2024-03-15 10:00:00.5');
SELECT timediff('2024-03-15', '2024-03-15');
SELECT timediff('2024-03-15 00:00:00', '2023-03-15 00:00:01');
SELECT timediff('2024-02-29', '2023-02-28');
SELECT timediff('2000-01-01', '2024-03-15 12:34:56.789');
SELECT timediff('2025-01-01 00:00:00', '2024-12-31 23:59:59.999');
-- Across a month boundary.
SELECT timediff('2024-03-01', '2024-02-28'), timediff('2023-03-01', '2023-02-28');
-- Time-only values (both on 2000-01-01).
SELECT timediff('18:00', '09:30');
-- Julian day numbers are accepted.
SELECT timediff(2460385.5, 2460384.5);

-- NULL or invalid input gives NULL.
SELECT timediff(NULL, '2024-01-01'), timediff('2024-01-01', NULL), timediff('x', '2024-01-01');

-- Result type.
SELECT typeof(timediff('2024-03-15', '2024-01-01'));

-- Applying the result as a modifier to B gives back A.
SELECT datetime('2024-01-01', timediff('2024-03-15 06:00:00', '2024-01-01'));

-- On a table.
CREATE TABLE t(id INTEGER, a TEXT, b TEXT);
INSERT INTO t VALUES (1, '2024-06-01', '2024-01-15'), (2, '2024-01-15', '2024-06-01'), (3, '2024-01-01 10:00', '2024-01-01 09:15:30');
SELECT id, timediff(a, b) FROM t ORDER BY id;
-- Wrong number of arguments.
SELECT timediff('2024-01-01');
