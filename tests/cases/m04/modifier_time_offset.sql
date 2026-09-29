-- '±HH:MM' and '±HH:MM:SS' modifiers add or subtract a time span.
SELECT datetime('2024-03-15 10:00', '+01:30'), datetime('2024-03-15 10:00', '-00:45');
SELECT datetime('2024-03-15 10:00', '+10:00'), datetime('2024-03-15 10:00', '+23:59:59');
SELECT datetime('2024-03-15 10:00', '-10:30:15'), datetime('2024-03-15 00:00', '-00:00:01');
SELECT datetime('2024-03-15 23:00', '+02:00'), date('2024-03-15 23:00', '+02:00');
-- Fractional seconds in the offset.
SELECT datetime('2024-03-15 10:00', '+00:00:00.5', 'subsec');
-- Hours beyond 24 are allowed.
SELECT datetime('2024-03-15 10:00', '+48:00');
-- On a time-only value.
SELECT time('08:15', '+01:50'), time('00:10', '-00:20');
-- Chained with other modifiers.
SELECT datetime('2024-03-15 10:00', '+1 day', '+01:00', '-30 minutes');
SELECT datetime('2024-03-15 10:00', '+01:00', 'start of day');

-- Malformed offsets give NULL.
SELECT datetime('2024-03-15 10:00', '+1:30'), datetime('2024-03-15 10:00', '+01:60'), datetime('2024-03-15 10:00', '01:30:');

-- Applying a zone-like offset stored in a column.
CREATE TABLE z(city TEXT, off TEXT);
INSERT INTO z VALUES ('tokyo', '+09:00'), ('nyc', '-05:00'), ('delhi', '+05:30'), ('utc', '+00:00');
SELECT city, datetime('2024-03-15 20:00:00', off) FROM z ORDER BY city;
SELECT city, date('2024-03-15 20:00:00', off) AS d FROM z ORDER BY d, city;
